//! A real server for the integration tests: a temp SQLite file, a temp local chunk store, the
//! production router bound to 127.0.0.1:0. Everything the corpus cannot see is driven through
//! this — the service layer directly, or HTTP where the handler's own behaviour (a broadcast,
//! a body limit) is the thing under test.

#![allow(dead_code, clippy::too_many_arguments)]

use std::collections::HashMap;
use std::sync::Arc;

use serde_json::{Value, json};
use tempfile::TempDir;
use tinkerex_sync::config::{Config, DatabaseConfig};
use tinkerex_sync::db::{Db, Query};
use tinkerex_sync::http::{AppState, State, router};
use tinkerex_sync::ids::{new_uuid, sha256_hex};
use tinkerex_sync::schema;
use tinkerex_sync::services::commit::{self, BeginParams, Finalized};
use tinkerex_sync::services::nudge::Hub;
use tinkerex_sync::services::provisioning::{self, IssuedDevice};
use tinkerex_sync::store::{ChunkStore, LocalChunkStore};
use tinkerex_sync::time::Timestamp;

pub const SECRET: &str = "test-secret-key-base";
pub const ADMIN_TOKEN: &str = "test-admin-token";
pub const HOUR: i64 = 3600;
pub const DAY: i64 = 86_400;

pub struct TestServer {
    pub base_url: String,
    pub state: State,
    pub db: Db,
    _dir: TempDir,
    task: tokio::task::JoinHandle<()>,
}

impl TestServer {
    /// A fresh SQLite database — or, with `TEST_DATABASE_URL` set, that Postgres database, which
    /// must be EMPTY at the start of a run (fixed emails across the test files collide on a reused
    /// one; a CI job creates it fresh, exactly as bin/conformance-rust demands). Every test in
    /// every binary switches together, so one `cargo test` run is one leg.
    pub async fn start() -> Self {
        Self::start_with(
            std::env::var("TEST_DATABASE_URL")
                .ok()
                .filter(|u| !u.is_empty()),
        )
        .await
    }

    /// `database`: `None` for a fresh temp SQLite file, or a `DATABASE_URL` (the Postgres leg).
    pub async fn start_with(database: Option<String>) -> Self {
        Self::start_from(database, HashMap::new()).await
    }

    /// The s3 store instead of the local blob tier (tests/s3_roundtrip.rs, against a real
    /// SeaweedFS/MinIO); the database is still a temp SQLite file unless `TEST_DATABASE_URL` says
    /// otherwise.
    pub async fn start_s3(
        endpoint: &str,
        bucket: &str,
        access_key_id: &str,
        secret_access_key: &str,
    ) -> Self {
        let storage = HashMap::from([
            ("STORAGE_BACKEND", "s3".to_string()),
            ("CHUNK_ENDPOINT", endpoint.to_string()),
            ("CHUNK_BUCKET", bucket.to_string()),
            ("CHUNK_REGION", "us-east-1".to_string()),
            ("CHUNK_ACCESS_KEY_ID", access_key_id.to_string()),
            ("CHUNK_SECRET_ACCESS_KEY", secret_access_key.to_string()),
        ]);
        Self::start_from(
            std::env::var("TEST_DATABASE_URL")
                .ok()
                .filter(|u| !u.is_empty()),
            storage,
        )
        .await
    }

    async fn start_from(database: Option<String>, storage: HashMap<&'static str, String>) -> Self {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("test.sqlite3");
        let chunk_dir = dir.path().join("chunks");
        let mut env: HashMap<&str, String> = HashMap::from([
            ("STORAGE_BACKEND", "local".to_string()),
            ("CHUNK_LOCAL_DIR", chunk_dir.to_string_lossy().into_owned()),
            ("SECRET_KEY_BASE", SECRET.to_string()),
            ("SYNC_ADMIN_TOKEN", ADMIN_TOKEN.to_string()),
        ]);
        env.extend(storage);
        match &database {
            Some(url) => {
                env.insert("DATABASE_URL", url.clone());
            }
            None => {
                env.insert("SQLITE_DATABASE", db_path.to_string_lossy().into_owned());
            }
        }
        let config = Config::from_lookup(&|k| env.get(k).cloned()).expect("config");
        assert!(
            matches!(&config.database, DatabaseConfig::Sqlite { .. }) == database.is_none(),
            "the database the harness resolved is not the one asked for"
        );
        let db = Db::connect(&config.database).await.expect("connect");
        {
            // Tests in one binary run on parallel threads; two first-ever `migrate`s against the
            // same Postgres database would race on CREATE TABLE. Serialize; the second adopts.
            static MIGRATE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
            let _one_at_a_time = MIGRATE.lock().await;
            schema::migrate(&db, "test").await.expect("migrate");
        }
        let store =
            ChunkStore::from_config(&config.storage, &config.secret_key_base).expect("store");
        let state: State = Arc::new(AppState {
            db: db.clone(),
            store,
            config,
            hub: Hub::new(),
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let addr = listener.local_addr().expect("addr");
        let app = router(state.clone());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("serve");
        });
        Self {
            base_url: format!("http://{addr}"),
            state,
            db,
            _dir: dir,
            task,
        }
    }

    pub fn store(&self) -> &ChunkStore {
        &self.state.store
    }

    pub fn local_store(&self) -> &LocalChunkStore {
        self.state.store.local().expect("a local store")
    }

    pub fn ws_url(&self, token: &str) -> String {
        format!(
            "{}/cable?token={token}",
            self.base_url.replacen("http://", "ws://", 1)
        )
    }

    pub async fn issue_device(&self, email: &str, name: &str) -> IssuedDevice {
        provisioning::issue_for_email(&self.db, email, name, Timestamp::now())
            .await
            .expect("issue a device")
    }

    pub fn http(&self) -> reqwest::Client {
        reqwest::Client::new()
    }

    /// One row's integer column, or `None` for no row.
    pub async fn scalar(&self, sql: &str, binds: &[Value]) -> Option<i64> {
        let mut q = Query::new(sql.to_string());
        for b in binds {
            q = match b {
                Value::Number(n) => q.bind(n.as_i64().expect("an integer bind")),
                Value::String(s) => q.bind(s.as_str()),
                other => panic!("unsupported bind {other:?}"),
            };
        }
        let db = self.db.clone();
        let row = db.fetch_optional(&q).await.expect("query");
        row.map(|r| r.i64("n").expect("column n"))
    }

    pub async fn refcount(&self, user_id: i64, hash: &str) -> Option<i64> {
        self.scalar(
            "SELECT refcount AS n FROM chunks WHERE user_id = $1 AND chunk_hash = $2",
            &[json!(user_id), json!(hash)],
        )
        .await
    }

    pub async fn chunk_rows(&self, user_id: i64) -> i64 {
        self.scalar(
            "SELECT count(*) AS n FROM chunks WHERE user_id = $1",
            &[json!(user_id)],
        )
        .await
        .unwrap_or(0)
    }

    pub async fn version_exists(&self, user_id: i64, version_id: &str) -> bool {
        self.scalar(
            "SELECT count(*) AS n FROM versions WHERE user_id = $1 AND version_id = $2",
            &[json!(user_id), json!(version_id)],
        )
        .await
        .unwrap_or(0)
            == 1
    }

    pub async fn pending_rows(&self, user_id: i64) -> i64 {
        self.scalar(
            "SELECT count(*) AS n FROM pending_commits WHERE user_id = $1",
            &[json!(user_id)],
        )
        .await
        .unwrap_or(0)
    }

    /// Backdate a chunk row's `updated_at` — the "bypass the touch" every Ruby sweep test used.
    pub async fn age_chunk(&self, user_id: i64, hash: &str, at: Timestamp) {
        let db = self.db.clone();
        db.execute(
            &Query::new("UPDATE chunks SET updated_at = $1 WHERE user_id = $2 AND chunk_hash = $3")
                .bind(at)
                .bind(user_id)
                .bind(hash),
        )
        .await
        .expect("age chunk");
    }

    pub async fn age_all_chunks(&self, user_id: i64, at: Timestamp) {
        let db = self.db.clone();
        db.execute(
            &Query::new("UPDATE chunks SET updated_at = $1 WHERE user_id = $2")
                .bind(at)
                .bind(user_id),
        )
        .await
        .expect("age chunks");
    }

    pub async fn age_pending(&self, user_id: i64, commit_id: &str, at: Timestamp) {
        let db = self.db.clone();
        db.execute(
            &Query::new(
                "UPDATE pending_commits SET created_at = $1 WHERE user_id = $2 AND commit_id = $3",
            )
            .bind(at)
            .bind(user_id)
            .bind(commit_id),
        )
        .await
        .expect("age pending");
    }

    pub async fn pin_version(&self, user_id: i64, version_id: &str) {
        let db = self.db.clone();
        db.execute(
            &Query::new("UPDATE versions SET pinned = $1 WHERE user_id = $2 AND version_id = $3")
                .bind(true)
                .bind(user_id)
                .bind(version_id),
        )
        .await
        .expect("pin");
    }

    /// Phase 1 of a commit: the pending row. Bytes are put into the store for every chunk.
    pub async fn begin(
        &self,
        user_id: i64,
        device_id: i64,
        node_id: &str,
        name: &str,
        base: Option<&str>,
        chunks: &[(String, i64)],
        now: Timestamp,
    ) -> String {
        let commit_id = new_uuid();
        let manifest: Vec<Value> = chunks.iter().map(|(h, l)| chunk(h, *l)).collect();
        commit::begin(
            &self.db,
            self.store(),
            &self.base_url,
            user_id,
            BeginParams {
                commit_id: Some(commit_id.clone()),
                node_id: Some(node_id.to_string()),
                parent_node_id: None,
                name: Some(name.to_string()),
                base_version_id: base.map(str::to_string),
                size: chunks.iter().map(|c| c.1).sum(),
                mode: None,
                mtime: None,
                manifest: &manifest,
                device_id: Some(device_id),
            },
            now,
        )
        .await
        .expect("begin");
        for (h, _) in chunks {
            self.store().put(user_id, h, b"bytes").await.expect("put");
        }
        commit_id
    }

    /// A whole commit: begin, bytes into the store, finalize.
    pub async fn commit_file(
        &self,
        user_id: i64,
        device_id: i64,
        node_id: &str,
        name: &str,
        base: Option<&str>,
        chunks: &[(String, i64)],
        now: Timestamp,
    ) -> Finalized {
        let commit_id = self
            .begin(user_id, device_id, node_id, name, base, chunks, now)
            .await;
        commit::finalize(&self.db, self.store(), user_id, &commit_id, true, now)
            .await
            .expect("finalize")
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// A fresh, well-formed 64-hex chunk hash.
pub fn hex() -> String {
    sha256_hex(new_uuid().as_bytes())
}

pub fn chunk(hash: &str, len: i64) -> Value {
    json!({ "hash": hash, "offset": 0, "length": len })
}

pub fn c(hash: &str) -> (String, i64) {
    (hash.to_string(), 5)
}

/// The frozen clock the Ruby GC suites ran under: midday UTC, so tiered buckets never straddle
/// a day boundary.
pub fn frozen_now() -> Timestamp {
    Timestamp::from_naive(
        chrono::NaiveDate::from_ymd_opt(2026, 6, 1)
            .expect("date")
            .and_hms_opt(12, 0, 0)
            .expect("time"),
    )
}
