//! The read services must cost a number of statements that is CONSTANT in the size of the
//! answer (plan §4 task 1.6): `tree` and `changes` batch their manifest and version loads, and a
//! per-row query would only show up as a slowdown nobody measures. Counted through sqlx's own
//! `sqlx::query` tracing events on a GLOBAL subscriber — the SQLite driver runs statements on its
//! worker thread, where a thread-local subscriber would see nothing — which is why this file
//! holds exactly one test: another test's queries in the same binary would pollute the count.
//! The count for the small case must be nonzero, so a counter that stopped counting fails loudly
//! instead of proving equality of two zeros.

mod support;

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use support::{TestServer, c, hex};
use tinkerex_sync::ids::new_uuid;
use tinkerex_sync::services::{changes, tree};
use tracing::Subscriber;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

struct StatementCounter(Arc<AtomicUsize>);

impl<S: Subscriber> Layer<S> for StatementCounter {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target().starts_with("sqlx::query") {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
}

async fn populate(server: &TestServer, user_id: i64, device_id: i64, files: usize) {
    let now = support::frozen_now();
    for i in 0..files {
        server
            .commit_file(
                user_id,
                device_id,
                &new_uuid(),
                &format!("f{i}.bin"),
                None,
                &[c(&hex()), c(&hex())],
                now,
            )
            .await;
    }
}

#[tokio::test]
async fn tree_and_changes_cost_a_constant_number_of_statements() {
    let counter = Arc::new(AtomicUsize::new(0));
    let subscriber = tracing_subscriber::registry().with(StatementCounter(counter.clone()));
    tracing::subscriber::set_global_default(subscriber)
        .expect("the only subscriber in this binary");

    let server = TestServer::start().await;
    let small = server.issue_device("budget-small@test.example", "d").await;
    let large = server.issue_device("budget-large@test.example", "d").await;
    populate(&server, small.user_id, small.device_id, 2).await;
    populate(&server, large.user_id, large.device_id, 40).await;

    async fn measure<F: std::future::Future<Output = ()>>(counter: &AtomicUsize, f: F) -> usize {
        counter.store(0, Ordering::SeqCst);
        f.await;
        counter.load(Ordering::SeqCst)
    }

    let db = &server.db;
    let tree_small = measure(&counter, async {
        tree::call(db, small.user_id, 0, 1000).await.unwrap();
    })
    .await;
    let tree_large = measure(&counter, async {
        tree::call(db, large.user_id, 0, 1000).await.unwrap();
    })
    .await;
    assert!(
        tree_small > 0,
        "the counter must see sqlx's statement events"
    );
    assert_eq!(
        tree_small, tree_large,
        "tree: {tree_small} statements for 2 files vs {tree_large} for 40"
    );

    let ch_small = measure(&counter, async {
        changes::call(db, small.user_id, 0, 1000).await.unwrap();
    })
    .await;
    let ch_large = measure(&counter, async {
        changes::call(db, large.user_id, 0, 1000).await.unwrap();
    })
    .await;
    assert!(ch_small > 0);
    assert_eq!(
        ch_small, ch_large,
        "changes: {ch_small} statements for 2 files vs {ch_large} for 40"
    );
}
