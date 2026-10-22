//! The schema, in the shape Rails left it, and how a database is adopted or created.
//!
//! `sqlite.sql` is the DDL the Rails host's own `db:prepare` emitted, verbatim — constraint names
//! included — so a database this binary creates is indistinguishable from one Rails created, and
//! the Ruby image can still boot on it (the rollback story). `postgres.sql` is the same schema in
//! Active Record's Postgres spelling. Neither file carries comments: they are split on `;`.
//!
//! On an existing Rails database nothing Rails created is recreated: the two Rails migration
//! versions are checked and the run is recorded as an adoption. Then, on either kind, the
//! binary's OWN migrations (`OWN_MIGRATIONS`) that `tinkerex_sync_migrations` does not yet record
//! are applied in order, each in one transaction with its version row. They only ever ADD
//! nullable columns, so the Rails schema's rows still read as Rails rows, and the Ruby image could
//! still boot on the file (CLAUDE.md §0.4).

use anyhow::{Context as _, bail};

use crate::db::{Db, Dialect, Query};
use crate::time::Timestamp;

const SQLITE_DDL: &str = include_str!("sqlite.sql");
const POSTGRES_DDL: &str = include_str!("postgres.sql");

/// The two migrations the Rails host ran (its `db/migrate/`, deleted with the Ruby in Phase 6): the
/// host tables, then the engine's eight.
pub const RAILS_SCHEMA_VERSIONS: [&str; 2] = ["20260101000001", "20260101000002"];
/// `Digest::SHA1.hexdigest(File.read("db/schema.rb"))` over the Rails host's schema file — what
/// Rails records in `ar_internal_metadata` when it loads that schema. Kept for fidelity of a fresh
/// database.
pub const RAILS_SCHEMA_SHA1: &str = "6dfa4503bec5b6521cffadb6fc75dca91ada2c68";

const OWN_MIGRATIONS_TABLE: &str = "tinkerex_sync_migrations";

/// One schema change the Rails schema never had, in both dialects' spelling.
pub struct OwnMigration {
    pub version: &'static str,
    pub summary: &'static str,
    sqlite: &'static [&'static str],
    postgres: &'static [&'static str],
}

/// Applied in this order, never edited once shipped: a deployed volume records each version.
pub const OWN_MIGRATIONS: &[OwnMigration] = &[OwnMigration {
    version: "20261022000001",
    summary: "devices.issuer_device_id and devices.revoked_at (revocation and idle expiry, tinkerex#473)",
    // `issuer_device_id`: the device whose token minted this one through `POST /v1/devices`; NULL
    // for a library credential (the admin door, `device issue`) and for every row older than this
    // migration. `revoked_at`: set by a revoke, never cleared; the row is kept so the names in
    // conflicts and locks still resolve.
    sqlite: &[
        "ALTER TABLE \"devices\" ADD \"issuer_device_id\" bigint",
        "ALTER TABLE \"devices\" ADD \"revoked_at\" datetime(6)",
    ],
    postgres: &[
        "ALTER TABLE devices ADD issuer_device_id bigint",
        "ALTER TABLE devices ADD revoked_at timestamp(6) without time zone",
    ],
}];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// A fresh database: the schema was created and the Rails bookkeeping rows written.
    Created,
    /// A Rails-created (or previously adopted) database with both migration versions present.
    Adopted,
}

pub async fn table_exists(db: &Db, name: &str) -> anyhow::Result<bool> {
    let q = match db.dialect() {
        Dialect::Sqlite => Query::new("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = $1").bind(name),
        Dialect::Postgres => Query::new(
            "SELECT count(*) AS n FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1",
        )
        .bind(name),
    };
    Ok(db.fetch_one(&q).await?.i64("n")? > 0)
}

/// Bring the database to the shape the server expects. `environment` is what a fresh database
/// records in `ar_internal_metadata` (Rails reads its own `RAILS_ENV` there).
pub async fn migrate(db: &Db, environment: &str) -> anyhow::Result<Outcome> {
    let has_users = table_exists(db, "users").await?;
    let has_migrations = table_exists(db, "schema_migrations").await?;

    let outcome = match (has_users, has_migrations) {
        (false, false) => {
            create_fresh(db, environment).await?;
            Outcome::Created
        }
        (true, true) => {
            verify_rails_versions(db).await?;
            Outcome::Adopted
        }
        (true, false) => bail!(
            "the database has a users table but no schema_migrations table; refusing to guess its state"
        ),
        (false, true) => bail!(
            "the database has schema_migrations but no users table; refusing to guess its state"
        ),
    };

    ensure_own_migrations_table(db).await?;
    for m in pending_own_migrations(db).await? {
        apply_own_migration(db, m).await?;
    }
    Ok(outcome)
}

/// The own migrations a database has not recorded, in order -- every one of them when the
/// bookkeeping table itself is absent. `serve` refuses to start while this is non-empty: every
/// device query names the columns they add, so the server would answer 500 to every request
/// while `/up` (which reads only `users`) reported it healthy.
pub async fn pending_own_migrations(db: &Db) -> anyhow::Result<Vec<&'static OwnMigration>> {
    if !table_exists(db, OWN_MIGRATIONS_TABLE).await? {
        return Ok(OWN_MIGRATIONS.iter().collect());
    }
    let rows = db
        .fetch_all(&Query::new(format!(
            "SELECT version FROM {OWN_MIGRATIONS_TABLE}"
        )))
        .await?;
    let applied: Vec<String> = rows
        .iter()
        .map(|r| r.str("version"))
        .collect::<Result<_, _>>()?;
    Ok(OWN_MIGRATIONS
        .iter()
        .filter(|m| !applied.iter().any(|a| a == m.version))
        .collect())
}

async fn apply_own_migration(db: &Db, m: &OwnMigration) -> anyhow::Result<()> {
    let statements = match db.dialect() {
        Dialect::Sqlite => m.sqlite,
        Dialect::Postgres => m.postgres,
    };
    let mut tx = db.begin().await?;
    for stmt in statements {
        tx.execute(&Query::new(*stmt))
            .await
            .with_context(|| format!("migration {}: {stmt}", m.version))?;
    }
    tx.execute(
        &Query::new(format!(
            "INSERT INTO {OWN_MIGRATIONS_TABLE} (version, applied_at) VALUES ($1, $2)"
        ))
        .bind(m.version)
        .bind(Timestamp::now()),
    )
    .await?;
    tx.commit().await?;
    Ok(())
}

fn statements(ddl: &str) -> impl Iterator<Item = &str> {
    ddl.split(';').map(str::trim).filter(|s| !s.is_empty())
}

async fn create_fresh(db: &Db, environment: &str) -> anyhow::Result<()> {
    let ddl = match db.dialect() {
        Dialect::Sqlite => SQLITE_DDL,
        Dialect::Postgres => POSTGRES_DDL,
    };
    for stmt in statements(ddl) {
        db.execute(&Query::new(stmt))
            .await
            .with_context(|| format!("running: {stmt}"))?;
    }
    for version in RAILS_SCHEMA_VERSIONS {
        db.execute(
            &Query::new("INSERT INTO schema_migrations (version) VALUES ($1)").bind(version),
        )
        .await?;
    }
    let now = Timestamp::now();
    for (key, value) in [
        ("environment", environment),
        ("schema_sha1", RAILS_SCHEMA_SHA1),
    ] {
        db.execute(
            &Query::new("INSERT INTO ar_internal_metadata (key, value, created_at, updated_at) VALUES ($1, $2, $3, $4)")
                .bind(key)
                .bind(value)
                .bind(now)
                .bind(now),
        )
        .await?;
    }
    Ok(())
}

async fn verify_rails_versions(db: &Db) -> anyhow::Result<()> {
    let rows = db
        .fetch_all(&Query::new("SELECT version FROM schema_migrations"))
        .await?;
    let present: Vec<String> = rows
        .iter()
        .map(|r| r.str("version"))
        .collect::<Result<_, _>>()?;
    let missing: Vec<&str> = RAILS_SCHEMA_VERSIONS
        .iter()
        .copied()
        .filter(|v| !present.iter().any(|p| p == v))
        .collect();
    if !missing.is_empty() {
        bail!(
            "the database is missing Rails migration version(s) {}; it was never fully migrated by the Ruby host and \
             this binary does not run Rails migrations",
            missing.join(", ")
        );
    }
    for table in [
        "devices",
        "nodes",
        "versions",
        "manifest_chunks",
        "chunks",
        "changelog_entries",
        "pending_commits",
        "conflicts",
        "file_locks",
        "share_links",
    ] {
        if !table_exists(db, table).await? {
            bail!("schema_migrations says the schema is complete, but table {table} is missing");
        }
    }
    Ok(())
}

async fn ensure_own_migrations_table(db: &Db) -> anyhow::Result<()> {
    if table_exists(db, OWN_MIGRATIONS_TABLE).await? {
        return Ok(());
    }
    let ddl = match db.dialect() {
        Dialect::Sqlite => format!(
            "CREATE TABLE \"{OWN_MIGRATIONS_TABLE}\" (\"version\" varchar NOT NULL PRIMARY KEY, \"applied_at\" datetime(6) NOT NULL)"
        ),
        Dialect::Postgres => format!(
            "CREATE TABLE {OWN_MIGRATIONS_TABLE} (version character varying NOT NULL PRIMARY KEY, applied_at timestamp(6) without time zone NOT NULL)"
        ),
    };
    db.execute(&Query::new(ddl)).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::DatabaseConfig;

    async fn temp_sqlite() -> (tempfile::TempDir, Db) {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::connect(&DatabaseConfig::Sqlite {
            path: dir.path().join("t.sqlite3"),
        })
        .await
        .unwrap();
        (dir, db)
    }

    #[tokio::test]
    async fn a_fresh_sqlite_database_gets_the_rails_shape_and_bookkeeping() {
        let (_dir, db) = temp_sqlite().await;
        assert_eq!(migrate(&db, "production").await.unwrap(), Outcome::Created);
        // Every table Rails created, by the names Rails gave them.
        for t in [
            "users",
            "devices",
            "nodes",
            "versions",
            "manifest_chunks",
            "chunks",
            "changelog_entries",
            "pending_commits",
            "conflicts",
            "file_locks",
            "share_links",
            "schema_migrations",
            "ar_internal_metadata",
        ] {
            assert!(table_exists(&db, t).await.unwrap(), "{t} missing");
        }
        let versions = db
            .fetch_all(&Query::new(
                "SELECT version FROM schema_migrations ORDER BY version",
            ))
            .await
            .unwrap();
        let versions: Vec<String> = versions.iter().map(|r| r.str("version").unwrap()).collect();
        assert_eq!(versions, RAILS_SCHEMA_VERSIONS);
        let env = db
            .fetch_one(&Query::new(
                "SELECT value FROM ar_internal_metadata WHERE key = 'environment'",
            ))
            .await
            .unwrap();
        assert_eq!(env.str("value").unwrap(), "production");
        // The constraint names Rails derives from a SHA-256 of "<table>_user_id_fk".
        let sql = db
            .fetch_one(&Query::new(
                "SELECT sql FROM sqlite_master WHERE name = 'versions'",
            ))
            .await
            .unwrap()
            .str("sql")
            .unwrap();
        assert!(sql.contains("fk_rails_914f13c63b"), "{sql}");
        // Running again adopts rather than recreating.
        assert_eq!(migrate(&db, "production").await.unwrap(), Outcome::Adopted);
    }

    async fn has_column(db: &Db, table: &str, column: &str) -> bool {
        db.fetch_one(
            &Query::new("SELECT count(*) AS n FROM pragma_table_info($1) WHERE name = $2")
                .bind(table)
                .bind(column),
        )
        .await
        .unwrap()
        .i64("n")
        .unwrap()
            == 1
    }

    async fn recorded_own_versions(db: &Db) -> Vec<String> {
        db.fetch_all(&Query::new(
            "SELECT version FROM tinkerex_sync_migrations ORDER BY version",
        ))
        .await
        .unwrap()
        .iter()
        .map(|r| r.str("version").unwrap())
        .collect()
    }

    #[tokio::test]
    async fn a_fresh_database_gets_every_own_migration_recorded_once() {
        let (_dir, db) = temp_sqlite().await;
        migrate(&db, "production").await.unwrap();
        assert!(has_column(&db, "devices", "issuer_device_id").await);
        assert!(has_column(&db, "devices", "revoked_at").await);
        let all: Vec<&str> = OWN_MIGRATIONS.iter().map(|m| m.version).collect();
        assert!(
            !all.is_empty(),
            "the list this test checks must not be empty"
        );
        assert_eq!(recorded_own_versions(&db).await, all);
        assert!(pending_own_migrations(&db).await.unwrap().is_empty());
        // A second run applies nothing: re-running an ADD COLUMN would fail loudly.
        assert_eq!(migrate(&db, "production").await.unwrap(), Outcome::Adopted);
        assert_eq!(recorded_own_versions(&db).await, all);
    }

    /// The deployed volume's case: a file Rails created (no own bookkeeping, no new columns) with
    /// a device already in it. Adoption adds the columns around the row, which keeps NULLs --
    /// which is what makes every pre-existing device a library credential (`models::Device`).
    #[tokio::test]
    async fn adopting_a_rails_file_adds_the_columns_around_its_existing_rows() {
        let (_dir, db) = temp_sqlite().await;
        create_fresh(&db, "production").await.unwrap();
        db.execute(&Query::new(
            "INSERT INTO users (email, head_seq, created_at, updated_at) VALUES ('old@example.com', 0, '2026-08-01 00:00:00', '2026-08-01 00:00:00')",
        ))
        .await
        .unwrap();
        db.execute(&Query::new(
            "INSERT INTO devices (user_id, name, token_digest, created_at, updated_at) VALUES (1, 'old', 'abc', '2026-08-01 00:00:00', '2026-08-01 00:00:00')",
        ))
        .await
        .unwrap();
        assert!(!has_column(&db, "devices", "revoked_at").await);
        assert_eq!(
            pending_own_migrations(&db).await.unwrap().len(),
            OWN_MIGRATIONS.len()
        );

        assert_eq!(migrate(&db, "production").await.unwrap(), Outcome::Adopted);
        assert!(has_column(&db, "devices", "issuer_device_id").await);
        assert!(has_column(&db, "devices", "revoked_at").await);
        let row = db
            .fetch_one(&Query::new(
                "SELECT name, issuer_device_id, revoked_at FROM devices",
            ))
            .await
            .unwrap();
        assert_eq!(row.str("name").unwrap(), "old");
        assert_eq!(row.opt_i64("issuer_device_id").unwrap(), None);
        assert_eq!(row.opt_time("revoked_at").unwrap(), None);
        assert!(pending_own_migrations(&db).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_half_migrated_database_is_refused() {
        let (_dir, db) = temp_sqlite().await;
        migrate(&db, "production").await.unwrap();
        db.execute(&Query::new(
            "DELETE FROM schema_migrations WHERE version = '20260101000002'",
        ))
        .await
        .unwrap();
        let err = migrate(&db, "production").await.unwrap_err().to_string();
        assert!(err.contains("20260101000002"), "{err}");
    }
}
