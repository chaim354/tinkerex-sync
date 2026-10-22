//! The binary: `serve`, and the operator subcommands that replace the Rails host's rake tasks
//! (`device issue`/`device list` print the exact lines `sync:device:issue`/`sync:device:list`
//! printed, because the maker repo's scripts parse them).

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use anyhow::Context as _;
use clap::{Parser, Subcommand};

use tinkerex_sync::config::{self, Config, DatabaseConfig, StorageConfig};
use tinkerex_sync::db::Db;
use tinkerex_sync::http::{AppState, ROUTES, router};
use tinkerex_sync::models::{ChangelogEntry, Device, Node, User, Version, chunk_count};
use tinkerex_sync::scheduler;
use tinkerex_sync::services::doctor::{self as pooler, PoolerCheck};
use tinkerex_sync::services::nudge::Hub;
use tinkerex_sync::services::provisioning;
use tinkerex_sync::services::retention::Policy;
use tinkerex_sync::services::revocation;
use tinkerex_sync::services::{gc, reapers};
use tinkerex_sync::store::ChunkStore;
use tinkerex_sync::time::Timestamp;
use tinkerex_sync::{db::Query, schema};

#[derive(Parser)]
#[command(name = "tinkerex-sync", version, about = "The tinkerex sync server")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Serve the v1 API.
    Serve {
        #[arg(long, env = "BIND", default_value = "0.0.0.0")]
        bind: IpAddr,
        #[arg(long, short = 'p', env = "PORT", default_value_t = 3000)]
        port: u16,
        /// Bring the database to shape first (what the Docker entrypoint does for the server only).
        #[arg(long)]
        migrate: bool,
        /// Run the maintenance jobs in-process (reap-pending hourly, retention nightly,
        /// reap-storage weekly). Off by default: turn it on only after reading the dry-runs.
        /// SYNC_SCHEDULER takes 1/0, yes/no, true/false, on/off: clap's plain bool parser took only
        /// true/false, and `SYNC_SCHEDULER=1` -- the value this crate's own README documented and
        /// the cutover plan prescribed -- put production in a restart loop on 2026-10-14
        /// (`invalid value '1' for '--scheduler'`). `--scheduler` alone still means on.
        #[arg(long, env = "SYNC_SCHEDULER", value_parser = clap::builder::BoolishValueParser::new(),
              num_args = 0..=1, default_missing_value = "true", default_value = "false")]
        scheduler: bool,
    },
    /// Create the schema on a fresh database, or adopt a Rails-created one.
    Migrate {
        /// What a fresh database records in `ar_internal_metadata` (Rails reads its own RAILS_ENV).
        #[arg(long, default_value = "production")]
        environment: String,
    },
    /// Device credentials.
    Device {
        #[command(subcommand)]
        command: DeviceCommand,
    },
    /// Row counts, in the shape the maker repo's backup and restore scripts read.
    Stats {
        /// One line, `<n> nodes, <m> versions`, for `bin/restore-db`'s verification step.
        #[arg(long)]
        brief: bool,
    },
    /// Every route this binary serves, one per line.
    Routes,
    /// Garbage collection, one pass now: retention, or one of the two orphan reapers.
    Gc {
        #[command(subcommand)]
        command: GcCommand,
    },
    /// Report the configuration and, on Postgres, probe for a statement-mode connection pooler.
    Doctor,
}

#[derive(Subcommand)]
enum GcCommand {
    /// Apply RETENTION_POLICY (keep_all, the default, prunes nothing) and sweep freed chunks.
    Retention {
        /// Seconds a zeroed chunk is left alone before its bytes are collected.
        #[arg(long, default_value_t = gc::DEFAULT_GRACE_SECS)]
        grace: i64,
        /// One user id; every user otherwise.
        #[arg(long)]
        user: Option<i64>,
        /// Count what would be pruned and touch nothing.
        #[arg(long)]
        dry_run: bool,
    },
    /// Reap the chunk bytes of EXPIRED, never-finalized pending commits (no bucket list).
    ReapPending {
        /// Hours a pending commit may stay un-finalized before it counts as abandoned.
        #[arg(long, default_value_t = 24.0)]
        ttl_hours: f64,
        #[arg(long)]
        user: Option<i64>,
        /// List what would be reaped and delete nothing.
        #[arg(long)]
        dry_run: bool,
    },
    /// List each user's keyspace and reap objects no row and no pending commit names (the weekly
    /// backstop; the list is billed per request on S3/R2).
    ReapStorage {
        /// Hours an object must be old before it can be reaped.
        #[arg(long, default_value_t = 24.0)]
        grace_hours: f64,
        #[arg(long)]
        user: Option<i64>,
        #[arg(long)]
        dry_run: bool,
    },
}

#[derive(Subcommand)]
enum DeviceCommand {
    /// Issue a device token for a user (creating the user if absent). Printed ONCE.
    Issue {
        #[arg(long, env = "EMAIL")]
        email: String,
        #[arg(long, env = "NAME", default_value = "device")]
        name: String,
    },
    /// List a user's devices, without revealing any token: id, name, last seen, then what kind of
    /// credential it is and whether it still authenticates.
    List {
        #[arg(long, env = "EMAIL")]
        email: String,
    },
    /// Revoke a device by id, and every device it minted. The one way to revoke a LIBRARY
    /// credential (the maker app's bootstrap token, a `device issue` token), which the HTTP door
    /// never does: nothing can mint that library another one except `device issue`.
    Revoke {
        #[arg(long)]
        id: i64,
    },
}

fn init_tracing() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .or_else(|_| {
            tracing_subscriber::EnvFilter::try_new(
                std::env::var("RAILS_LOG_LEVEL").unwrap_or_else(|_| "info".into()),
            )
        })
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    if std::env::var("SYNC_LOG_JSON")
        .map(|v| v == "1")
        .unwrap_or(false)
    {
        tracing_subscriber::fmt()
            .json()
            .with_env_filter(filter)
            .init();
    } else {
        tracing_subscriber::fmt()
            .compact()
            .with_env_filter(filter)
            .init();
    }
}

async fn open_db() -> anyhow::Result<Db> {
    let cfg = DatabaseConfig::from_lookup(&|k| std::env::var(k).ok())?;
    Db::connect(&cfg)
        .await
        .context("connecting to the database")
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    match Cli::parse().command {
        Command::Serve {
            bind,
            port,
            migrate,
            scheduler,
        } => serve(bind, port, migrate, scheduler).await,
        Command::Gc { command } => run_gc(command).await,
        Command::Doctor => doctor().await,
        Command::Migrate { environment } => {
            let db = open_db().await?;
            let pending = schema::pending_own_migrations(&db).await?;
            let outcome = schema::migrate(&db, &environment).await?;
            // stdout stays the one word bin/conformance and the entrypoint's log expect.
            println!("{outcome:?}");
            for m in pending {
                eprintln!("applied migration {}: {}", m.version, m.summary);
            }
            Ok(())
        }
        Command::Device { command } => device(command).await,
        Command::Stats { brief } => stats(brief).await,
        Command::Routes => {
            for (method, path) in ROUTES {
                println!("{method} {path}");
            }
            Ok(())
        }
    }
}

async fn serve(bind: IpAddr, port: u16, migrate: bool, scheduler: bool) -> anyhow::Result<()> {
    let config = Config::from_env()?;
    let db = Db::connect(&config.database)
        .await
        .context("connecting to the database")?;
    if migrate {
        let outcome = schema::migrate(&db, "production").await?;
        tracing::info!(?outcome, "database ready");
    } else if !schema::table_exists(&db, "users").await? {
        tracing::warn!(
            "the database has no schema; run `tinkerex-sync migrate` (or serve --migrate)"
        );
    } else {
        let pending = schema::pending_own_migrations(&db).await?;
        if !pending.is_empty() {
            let versions: Vec<&str> = pending.iter().map(|m| m.version).collect();
            anyhow::bail!(
                "the database is missing migration(s) {}; every device query needs them, so this server \
                 would answer 500 to every request while /up said ok. Run `tinkerex-sync migrate` \
                 (or serve --migrate) first",
                versions.join(", ")
            );
        }
    }
    pooler_check_at_boot(&db).await?;
    let store = ChunkStore::from_config(&config.storage, &config.secret_key_base)?;
    let state = Arc::new(AppState {
        db,
        store,
        config,
        hub: Hub::new(),
    });
    if scheduler {
        scheduler::spawn(state.clone());
        tracing::info!("scheduler on: reap-pending hourly, retention nightly, reap-storage weekly");
    }
    let addr = SocketAddr::new(bind, port);
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    tracing::info!(%addr, "tinkerex-sync listening");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async { tokio::signal::ctrl_c().await.ok() };
    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("SIGTERM handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = terminate => {} }
    tracing::info!("shutting down");
}

async fn device(command: DeviceCommand) -> anyhow::Result<()> {
    let db = open_db().await?;
    match command {
        DeviceCommand::Issue { email, name } => {
            let issued =
                provisioning::issue_for_email(&db, &email, &name, Timestamp::now()).await?;
            println!("user_id:      {}", issued.user_id);
            println!("device_id:    {}", issued.device_id);
            println!("device_token: {}", issued.device_token);
            println!();
            println!("Store it now -- only its digest is kept, so this cannot be shown again.");
        }
        DeviceCommand::List { email } => {
            let mut dbh = db.clone();
            let user = User::find_by_email(&mut dbh, &email)
                .await?
                .with_context(|| format!("no user with email {email}"))?;
            let idle_days =
                config::device_idle_days(std::env::var("DEVICE_IDLE_DAYS").ok().as_deref());
            let now = Timestamp::now();
            for d in Device::list_for_user(&mut dbh, user.id).await? {
                let seen = d
                    .last_seen_at
                    .map(|t| t.to_json())
                    .unwrap_or_else(|| "never".into());
                let kind = match d.issuer_device_id {
                    None => "library credential".to_string(),
                    Some(by) => format!("minted by {by}"),
                };
                let status = match d.revoked_at {
                    Some(t) => format!("revoked {}", t.to_json()),
                    None if d.idled_out(now, idle_days) => "idled out".to_string(),
                    None => "live".to_string(),
                };
                println!("{}\t{}\tlast seen {}\t{kind}\t{status}", d.id, d.name, seen);
            }
        }
        DeviceCommand::Revoke { id } => {
            match revocation::revoke_as_operator(&db, id, Timestamp::now()).await? {
                None => anyhow::bail!("no device with id {id}"),
                Some((target, ids)) => {
                    println!(
                        "revoked {} ({}) of user {}, and every device it minted: {}",
                        target.id,
                        target.name,
                        target.user_id,
                        ids.iter()
                            .map(i64::to_string)
                            .collect::<Vec<_>>()
                            .join(", ")
                    );
                    println!(
                        "a running server cuts their open sockets within its cable re-check ({} s)",
                        config::CABLE_RECHECK_DEFAULT.as_secs()
                    );
                }
            }
        }
    }
    Ok(())
}

async fn stats(brief: bool) -> anyhow::Result<()> {
    let mut db = open_db().await?;
    let nodes = Node::count(&mut db).await?;
    let versions = Version::count(&mut db).await?;
    if brief {
        println!("{nodes} nodes, {versions} versions");
        return Ok(());
    }
    async fn count(db: &Db, sql: &'static str) -> anyhow::Result<i64> {
        let db = db.clone();
        Ok(db.fetch_one(&Query::new(sql)).await?.i64("n")?)
    }
    println!("users                    {}", User::count(&mut db).await?);
    println!(
        "devices                  {}",
        count(&db, "SELECT count(*) AS n FROM devices").await?
    );
    println!("nodes                    {nodes}");
    println!("versions                 {versions}");
    println!("chunks                   {}", chunk_count(&mut db).await?);
    println!(
        "manifest_chunks          {}",
        count(&db, "SELECT count(*) AS n FROM manifest_chunks").await?
    );
    println!(
        "changelog_entries        {}",
        ChangelogEntry::count(&mut db).await?
    );
    Ok(())
}

/// The Postgres pooler probe at boot, per `SYNC_DB_POOLER_CHECK` (warn by default; `refuse`
/// makes a failed probe a boot failure; `skip`, or the Rails host's `DB_SKIP_POOLER_CHECK=1`,
/// does not probe). Nothing to do on SQLite.
async fn pooler_check_at_boot(db: &Db) -> anyhow::Result<()> {
    let mode = PoolerCheck::from_lookup(&|k| std::env::var(k).ok());
    if mode == PoolerCheck::Skip {
        return Ok(());
    }
    let Some(result) = pooler::probe(db).await else {
        return Ok(());
    };
    if result.ok {
        tracing::info!("postgres pooler check passed (session/transaction mode)");
        return Ok(());
    }
    let message = pooler::failure_message(&result);
    match mode {
        PoolerCheck::Refuse => anyhow::bail!("{message}"),
        _ => {
            tracing::warn!("{message}");
            Ok(())
        }
    }
}

fn hours_to_secs(hours: f64) -> i64 {
    (hours * 3600.0).round() as i64
}

async fn run_gc(command: GcCommand) -> anyhow::Result<()> {
    let config = Config::from_env()?;
    let db = Db::connect(&config.database)
        .await
        .context("connecting to the database")?;
    let store = ChunkStore::from_config(&config.storage, &config.secret_key_base)?;
    let now = Timestamp::now();
    let mut dbh = db.clone();
    match command {
        GcCommand::Retention {
            grace,
            user,
            dry_run,
        } => {
            let policy = Policy::from_mode(config.retention);
            let label = if dry_run { "would prune" } else { "pruned" };
            let users = match user {
                Some(id) => vec![id],
                None => User::all_ids(&mut dbh).await?,
            };
            let mut total = 0u64;
            for user_id in users {
                let n =
                    gc::apply_retention(&db, &store, user_id, policy, grace, dry_run, now).await?;
                println!("retention ({policy:?}) {label} {n} version(s) for user {user_id}");
                total += n;
            }
            println!("retention ({policy:?}) {label} {total} version(s) in total");
        }
        GcCommand::ReapPending {
            ttl_hours,
            user,
            dry_run,
        } => {
            let ttl = hours_to_secs(ttl_hours);
            let label = if dry_run {
                "[dry-run] would reap"
            } else {
                "reaped"
            };
            match user {
                Some(user_id) => {
                    let reaped =
                        reapers::reap_pending(&db, &store, user_id, ttl, dry_run, now).await?;
                    println!(
                        "reap-pending {label} {} orphan chunk(s) for user {user_id}",
                        reaped.len()
                    );
                    for h in reaped {
                        println!("  chunks/{user_id}/{h}");
                    }
                }
                None => {
                    let total = reapers::reap_pending_all(&db, &store, ttl, dry_run, now).await?;
                    println!("reap-pending {label} {total} orphan chunk(s) across all users");
                }
            }
        }
        GcCommand::ReapStorage {
            grace_hours,
            user,
            dry_run,
        } => {
            let grace = hours_to_secs(grace_hours);
            let label = if dry_run {
                "[dry-run] would reap"
            } else {
                "reaped"
            };
            match user {
                Some(user_id) => {
                    let reaped =
                        reapers::reap_storage(&db, &store, user_id, grace, dry_run, now).await?;
                    println!(
                        "reap-storage {label} {} orphan chunk(s) for user {user_id}",
                        reaped.len()
                    );
                    for h in reaped {
                        println!("  chunks/{user_id}/{h}");
                    }
                }
                None => {
                    let total = reapers::reap_storage_all(&db, &store, grace, dry_run, now).await?;
                    println!("reap-storage {label} {total} orphan chunk(s) across all users");
                }
            }
        }
    }
    Ok(())
}

/// Configuration and connectivity, printed; exits nonzero when something is wrong.
async fn doctor() -> anyhow::Result<()> {
    let config = Config::from_env()?;
    match &config.database {
        DatabaseConfig::Sqlite { path } => println!("database:      sqlite {}", path.display()),
        DatabaseConfig::Postgres { .. } => println!("database:      postgres (DATABASE_URL)"),
    }
    match &config.storage {
        StorageConfig::Local { dir, public_url } => println!(
            "storage:       local {} (public url: {})",
            dir.display(),
            public_url
                .as_deref()
                .unwrap_or("the request's own base url")
        ),
        StorageConfig::S3 {
            bucket,
            endpoint,
            region,
            ..
        } => println!(
            "storage:       s3 bucket={bucket} endpoint={} region={region}",
            endpoint.as_deref().unwrap_or("aws")
        ),
    }
    println!(
        "admin route:   {}",
        if config.admin_token.is_some() {
            "enabled (SYNC_ADMIN_TOKEN set)"
        } else {
            "disabled (503)"
        }
    );
    println!("retention:     {:?}", Policy::from_mode(config.retention));
    match config.device_idle_days {
        Some(days) => println!(
            "device expiry: a device credential idle {days} days stops authenticating (DEVICE_IDLE_DAYS)"
        ),
        None => println!("device expiry: off (DEVICE_IDLE_DAYS=0)"),
    }
    let db = Db::connect(&config.database)
        .await
        .context("connecting to the database")?;
    let mut failed = false;
    if schema::table_exists(&db, "users").await? {
        let pending = schema::pending_own_migrations(&db).await?;
        if pending.is_empty() {
            println!("schema:        present, every migration applied");
        } else {
            let versions: Vec<&str> = pending.iter().map(|m| m.version).collect();
            println!(
                "schema:        present, MISSING migration(s) {} -- run `tinkerex-sync migrate`",
                versions.join(", ")
            );
            failed = true;
        }
    } else {
        println!("schema:        MISSING -- run `tinkerex-sync migrate`");
        failed = true;
    }
    match pooler::probe(&db).await {
        None => println!("pooler check:  not applicable (sqlite)"),
        Some(r) if r.ok => println!("pooler check:  ok (session/transaction mode)"),
        Some(r) => {
            println!("pooler check:  FAILED");
            println!("{}", pooler::failure_message(&r));
            failed = true;
        }
    }
    if failed {
        anyhow::bail!("doctor found a problem");
    }
    Ok(())
}

#[cfg(test)]
mod scheduler_flag_tests {
    use super::*;
    use clap::Parser;

    fn scheduler_of(args: &[&str]) -> bool {
        match Cli::try_parse_from(args).expect("parses").command {
            Command::Serve { scheduler, .. } => scheduler,
            _ => unreachable!("serve is the only subcommand parsed here"),
        }
    }

    // ONE test, sequential on purpose: SYNC_SCHEDULER is process-global and clap reads it at
    // parse time, so two tests touching it would race.
    #[test]
    fn scheduler_flag_takes_every_boolish_spelling_and_defaults_off() {
        unsafe { std::env::remove_var("SYNC_SCHEDULER") };
        assert!(!scheduler_of(&["tinkerex-sync", "serve"]), "off by default");
        assert!(
            scheduler_of(&["tinkerex-sync", "serve", "--scheduler"]),
            "bare flag means on"
        );
        assert!(!scheduler_of(&[
            "tinkerex-sync",
            "serve",
            "--scheduler=false"
        ]));
        for (value, expected) in [
            ("1", true),
            ("0", false),
            ("true", true),
            ("false", false),
            ("yes", true),
            ("no", false),
            ("on", true),
            ("off", false),
        ] {
            unsafe { std::env::set_var("SYNC_SCHEDULER", value) };
            assert_eq!(
                scheduler_of(&["tinkerex-sync", "serve"]),
                expected,
                "SYNC_SCHEDULER={value}"
            );
        }
        unsafe { std::env::remove_var("SYNC_SCHEDULER") };
    }
}
