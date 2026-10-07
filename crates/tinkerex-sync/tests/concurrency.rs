//! The invariant behind the changelog: every mutation allocates its seq under the user row lock
//! BEFORE any other write, so concurrent writers never deadlock on a lock upgrade and the
//! changelog is gapless. On SQLite the transaction is `BEGIN IMMEDIATE`; on Postgres the row lock
//! is `FOR UPDATE`. The Postgres leg runs only with `TEST_DATABASE_URL` set and SAYS SO when it
//! does not — a silent skip would read as green (CLAUDE.md §5).

mod support;

use serde_json::json;
use support::{TestServer, c, hex};
use tinkerex_sync::models::User;
use tinkerex_sync::services::mutation::UserWrite;
use tinkerex_sync::time::Timestamp;

const WRITERS: usize = 16;
const PER_WRITER: usize = 25;

async fn seq_allocation_is_gapless(server: &TestServer) {
    let device = server
        .issue_device(&format!("seq-{}@test.example", hex()), "device")
        .await;
    let user_id = device.user_id;
    let mut tasks = Vec::new();
    for _ in 0..WRITERS {
        let db = server.db.clone();
        tasks.push(tokio::spawn(async move {
            let mut seqs = Vec::with_capacity(PER_WRITER);
            for _ in 0..PER_WRITER {
                let write = UserWrite::begin(&db, user_id).await.expect("begin");
                let seq = write.seq();
                write.commit().await.expect("commit");
                seqs.push(seq);
            }
            seqs
        }));
    }
    let mut all = Vec::new();
    for t in tasks {
        all.extend(t.await.expect("writer task"));
    }
    all.sort_unstable();
    let expected: Vec<i64> = (1..=(WRITERS * PER_WRITER) as i64).collect();
    assert_eq!(
        all, expected,
        "seqs must be 1..=N with no gap and no duplicate"
    );
    let mut db = server.db.clone();
    assert_eq!(
        User::head_seq(&mut db, user_id).await.expect("head_seq"),
        (WRITERS * PER_WRITER) as i64
    );
}

const COMMITTERS: usize = 8;
const COMMITS_EACH: usize = 10;

async fn concurrent_commits_leave_a_gapless_changelog(server: &TestServer) {
    let device = server
        .issue_device(&format!("commit-{}@test.example", hex()), "device")
        .await;
    let (user_id, device_id) = (device.user_id, device.device_id);
    let mut tasks = Vec::new();
    for w in 0..COMMITTERS {
        let db = server.db.clone();
        let store = server.state.clone();
        let base_url = server.base_url.clone();
        tasks.push(tokio::spawn(async move {
            let mut seqs = Vec::new();
            for i in 0..COMMITS_EACH {
                let node_id = tinkerex_sync::ids::new_uuid();
                let commit_id = tinkerex_sync::ids::new_uuid();
                let h = hex();
                let manifest = vec![support::chunk(&h, 5)];
                tinkerex_sync::services::commit::begin(
                    &db,
                    &store.store,
                    &base_url,
                    user_id,
                    tinkerex_sync::services::commit::BeginParams {
                        commit_id: Some(commit_id.clone()),
                        node_id: Some(node_id),
                        parent_node_id: None,
                        name: Some(format!("w{w}-{i}.bin")),
                        base_version_id: None,
                        size: 5,
                        mode: None,
                        mtime: None,
                        manifest: &manifest,
                        device_id: Some(device_id),
                    },
                    Timestamp::now(),
                )
                .await
                .expect("begin");
                store.store.put(user_id, &h, b"bytes").await.expect("put");
                let done = tinkerex_sync::services::commit::finalize(
                    &db,
                    &store.store,
                    user_id,
                    &commit_id,
                    true,
                    Timestamp::now(),
                )
                .await
                .expect("finalize");
                seqs.push(done.seq);
            }
            seqs
        }));
    }
    let mut all = Vec::new();
    for t in tasks {
        all.extend(t.await.expect("committer task"));
    }
    all.sort_unstable();
    let n = (COMMITTERS * COMMITS_EACH) as i64;
    assert_eq!(all, (1..=n).collect::<Vec<i64>>());
    let rows = server
        .scalar(
            "SELECT count(*) AS n FROM changelog_entries WHERE user_id = $1",
            &[json!(user_id)],
        )
        .await;
    assert_eq!(rows, Some(n), "one changelog entry per finalize");
    let distinct = server
        .scalar(
            "SELECT count(DISTINCT seq) AS n FROM changelog_entries WHERE user_id = $1",
            &[json!(user_id)],
        )
        .await;
    assert_eq!(distinct, Some(n), "no two entries share a seq");
    let _ = c("unused");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn sqlite_seq_allocation_is_gapless_under_contention() {
    let server = TestServer::start().await;
    seq_allocation_is_gapless(&server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn sqlite_concurrent_commits_leave_a_gapless_changelog() {
    let server = TestServer::start().await;
    concurrent_commits_leave_a_gapless_changelog(&server).await;
}

/// The Postgres leg. NOT a silent skip: without `TEST_DATABASE_URL` it prints that it did not
/// run, and the CI job that owns the Postgres claim greps for the line that says it did.
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn postgres_seq_allocation_and_commits_are_gapless() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("postgres leg NOT RUN: TEST_DATABASE_URL is unset");
        return;
    };
    let server = TestServer::start_with(Some(url)).await;
    seq_allocation_is_gapless(&server).await;
    concurrent_commits_leave_a_gapless_changelog(&server).await;
    eprintln!(
        "postgres leg RAN: {WRITERS}x{PER_WRITER} seq allocations and {COMMITTERS}x{COMMITS_EACH} commits gapless"
    );
}
