//! The schema, in the shape Rails left it, and how a database is adopted or created.
//!
//! `sqlite.sql` is the DDL the Rails host's own `db:prepare` emitted, verbatim — constraint names
//! included — so a database this binary creates is indistinguishable from one Rails created, and
//! the Ruby image can still boot on it (the rollback story). `postgres.sql` is the same schema in
//! Active Record's Postgres spelling. Neither file carries comments: they are split on `;`.
//!
//! On an existing Rails database nothing is created and nothing is altered; the two Rails
//! migration versions are checked and the run is recorded as an adoption.

use anyhow::{Context as _, bail};

use crate::db::{Db, Dialect, Query};
use crate::time::Timestamp;

const SQLITE_DDL: &str = include_str!("sqlite.sql");
const POSTGRES_DDL: &str = include_str!("postgres.sql");

/// `host/db/migrate/` in the Rails repo: the host tables, then the engine's eight.
pub const RAILS_SCHEMA_VERSIONS: [&str; 2] = ["20260101000001", "20260101000002"];
/// `Digest::SHA1.hexdigest(File.read("host/db/schema.rb"))` — what Rails records in
/// `ar_internal_metadata` when it loads that schema. Kept for fidelity of a fresh database.
pub const RAILS_SCHEMA_SHA1: &str = "6dfa4503bec5b6521cffadb6fc75dca91ada2c68";

const OWN_MIGRATIONS_TABLE: &str = "tinkerex_sync_migrations";

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
    Ok(outcome)
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
