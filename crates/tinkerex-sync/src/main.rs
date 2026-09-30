//! The binary: `serve`, and the operator subcommands that replace the Rails host's rake tasks
//! (`device issue`/`device list` print the exact lines `sync:device:issue`/`sync:device:list`
//! printed, because the maker repo's scripts parse them).

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use anyhow::Context as _;
use clap::{Parser, Subcommand};

use tinkerex_sync::config::{Config, DatabaseConfig};
use tinkerex_sync::db::Db;
use tinkerex_sync::http::{AppState, ROUTES, router};
use tinkerex_sync::models::{ChangelogEntry, Device, Node, User, Version, chunk_count};
use tinkerex_sync::services::nudge::Hub;
use tinkerex_sync::services::provisioning;
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
    /// List a user's devices, without revealing any token.
    List {
        #[arg(long, env = "EMAIL")]
        email: String,
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
        } => serve(bind, port, migrate).await,
        Command::Migrate { environment } => {
            let db = open_db().await?;
            let outcome = schema::migrate(&db, &environment).await?;
            println!("{outcome:?}");
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

async fn serve(bind: IpAddr, port: u16, migrate: bool) -> anyhow::Result<()> {
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
    }
    let store = ChunkStore::from_config(&config.storage, &config.secret_key_base)?;
    let state = Arc::new(AppState {
        db,
        store,
        config,
        hub: Hub::new(),
    });
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
            for d in Device::list_for_user(&mut dbh, user.id).await? {
                let seen = d
                    .last_seen_at
                    .map(|t| t.to_json())
                    .unwrap_or_else(|| "never".into());
                println!("{}\t{}\tlast seen {}", d.id, d.name, seen);
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
