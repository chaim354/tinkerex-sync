//! GC, retention and the two reapers — ported from the Ruby engine's `gc_test.rb`,
//! `chunk_reaper_test.rb` and `pending_commit_reaper_test.rb`, against the real service layer on
//! a real SQLite file and a real local chunk store. The clock is frozen at midday UTC as it was
//! there, and passed explicitly everywhere (`now`), so no assertion depends on the wall clock.

mod support;

use std::future::Future;

use support::{DAY, HOUR, TestServer, c, frozen_now, hex};
use tinkerex_sync::db::Db;
use tinkerex_sync::error::ApiError;
use tinkerex_sync::ids::{new_uuid, sha256_hex};
use tinkerex_sync::models::{
    ChunkRef, Conflict, KIND_FILE, Node, PendingCommit, ShareLink, Version, insert_chunks,
    insert_manifest, manifest_hashes, touch_refcounts,
};
use tinkerex_sync::services::commit::{self, BeginParams};
use tinkerex_sync::services::conflicts;
use tinkerex_sync::services::gc::{self, DeleteBytes};
use tinkerex_sync::services::reapers;
use tinkerex_sync::services::retention::Policy;
use tinkerex_sync::time::Timestamp;

struct Fx {
    server: TestServer,
    user_id: i64,
    device_id: i64,
    now: Timestamp,
}

async fn fixture(email: &str) -> Fx {
    let server = TestServer::start().await;
    let d = server.issue_device(email, "t").await;
    Fx {
        server,
        user_id: d.user_id,
        device_id: d.device_id,
        now: frozen_now(),
    }
}

impl Fx {
    async fn commit(&self, name: &str, chunks: &[(String, i64)]) -> Version {
        self.server
            .commit_file(
                self.user_id,
                self.device_id,
                &new_uuid(),
                name,
                None,
                chunks,
                self.now,
            )
            .await
            .version
    }

    /// N versions of one node, each with its own chunk (bytes in the store, refcount 1), spaced
    /// by age; the newest is the node's current version. Returns them in insertion order.
    async fn make_history(&self, node_id: &str, ages: &[i64]) -> Vec<Version> {
        let mut db = self.server.db.clone();
        let mut versions = Vec::new();
        for age in ages {
            let h = hex();
            self.server
                .store()
                .put(self.user_id, &h, b"bytes")
                .await
                .expect("put");
            let manifest_id = sha256_hex(new_uuid().as_bytes());
            insert_manifest(
                &mut db,
                self.user_id,
                &manifest_id,
                &[ChunkRef {
                    hash: h.clone(),
                    offset: 0,
                    length: 5,
                }],
            )
            .await
            .expect("manifest");
            insert_chunks(&mut db, self.user_id, &[(h, 5)], self.now)
                .await
                .expect("chunk row");
            let mut v = Version {
                id: None,
                user_id: self.user_id,
                version_id: new_uuid(),
                node_id: node_id.to_string(),
                manifest_id,
                size: 5,
                device_id: None,
                parent_version_id: None,
                pinned: false,
                created_at: self.now.minus_seconds(*age),
            };
            v.insert(&mut db).await.expect("version");
            versions.push(v);
        }
        let newest = versions
            .iter()
            .max_by_key(|v| v.created_at)
            .expect("at least one");
        let mut node = Node::new(self.user_id, node_id, self.now);
        node.name = "f".into();
        node.kind = KIND_FILE.into();
        node.current_version_id = Some(newest.version_id.clone());
        node.save(&mut db, self.now).await.expect("node");
        versions
    }

    async fn first_hash(&self, v: &Version) -> String {
        let mut db = self.server.db.clone();
        manifest_hashes(&mut db, self.user_id, &v.manifest_id)
            .await
            .expect("hashes")
            .remove(0)
    }

    async fn exists(&self, hash: &str) -> bool {
        self.server
            .store()
            .exists(self.user_id, hash)
            .await
            .expect("exists")
    }

    async fn refcount(&self, hash: &str) -> Option<i64> {
        self.server.refcount(self.user_id, hash).await
    }

    async fn prune(&self, v: &Version) -> bool {
        gc::prune_version(&self.server.db, self.user_id, v, self.now)
            .await
            .expect("prune")
    }

    async fn sweep(&self, grace: i64) -> u64 {
        gc::sweep_orphans(
            &self.server.db,
            self.server.store(),
            self.user_id,
            grace,
            self.now,
        )
        .await
        .expect("sweep")
    }

    async fn retain(&self, policy: Policy, grace: i64) -> u64 {
        gc::apply_retention(
            &self.server.db,
            self.server.store(),
            self.user_id,
            policy,
            grace,
            false,
            self.now,
        )
        .await
        .expect("retention")
    }

    /// A pending commit (phase 1 only) with its bytes uploaded, optionally backdated — the row
    /// AND the objects, so the storage-age guard sees an abandoned upload, not a fresh one.
    async fn pending(&self, chunks: &[(String, i64)], age: i64) -> PendingCommit {
        let commit_id = self
            .server
            .begin(
                self.user_id,
                self.device_id,
                &new_uuid(),
                "p",
                None,
                chunks,
                self.now,
            )
            .await;
        if age > 0 {
            let at = self.now.minus_seconds(age);
            self.server.age_pending(self.user_id, &commit_id, at).await;
            for (h, _) in chunks {
                self.server
                    .local_store()
                    .set_mtime(self.user_id, h, at)
                    .expect("mtime");
            }
        }
        let mut db = self.server.db.clone();
        PendingCommit::find(&mut db, self.user_id, &commit_id)
            .await
            .expect("find")
            .expect("the pending row")
    }

    async fn pending_row_exists(&self, id: i64) -> bool {
        self.server
            .scalar(
                "SELECT count(*) AS n FROM pending_commits WHERE id = $1",
                &[serde_json::json!(id)],
            )
            .await
            == Some(1)
    }

    /// A leaked object: bytes in storage, no row anywhere, aged.
    async fn upload(&self, age: i64) -> String {
        let h = hex();
        self.server
            .store()
            .put(self.user_id, &h, b"bytes")
            .await
            .expect("put");
        self.server
            .local_store()
            .set_mtime(self.user_id, &h, self.now.minus_seconds(age))
            .expect("mtime");
        h
    }

    async fn reap_storage(&self, grace: i64, dry_run: bool) -> Vec<String> {
        reapers::reap_storage(
            &self.server.db,
            self.server.store(),
            self.user_id,
            grace,
            dry_run,
            self.now,
        )
        .await
        .expect("reap-storage")
    }

    async fn reap_pending(&self, ttl: i64) -> Vec<String> {
        reapers::reap_pending(
            &self.server.db,
            self.server.store(),
            self.user_id,
            ttl,
            false,
            self.now,
        )
        .await
        .expect("reap-pending")
    }
}

// ---- prune_version / sweep_orphans -------------------------------------------------------------

#[tokio::test]
async fn prune_version_decrements_refcounts_and_destroys_the_version() {
    let fx = fixture("gc1@example.com").await;
    let (a, b) = (hex(), hex());
    let v1 = fx.commit("f", &[c(&a), c(&b)]).await;
    assert_eq!(fx.refcount(&a).await, Some(1));
    assert_eq!(fx.refcount(&b).await, Some(1));

    fx.prune(&v1).await;

    assert_eq!(fx.refcount(&a).await, Some(0));
    assert_eq!(fx.refcount(&b).await, Some(0));
    assert!(
        !fx.server.version_exists(fx.user_id, &v1.version_id).await,
        "version destroyed"
    );
}

#[tokio::test]
async fn prune_version_never_frees_a_chunk_still_referenced_by_another_version() {
    let fx = fixture("gc2@example.com").await;
    let shared = hex();
    let v1 = fx.commit("a", &[c(&shared)]).await;
    fx.commit("b", &[c(&shared)]).await;
    assert_eq!(fx.refcount(&shared).await, Some(2));

    fx.prune(&v1).await;
    assert_eq!(fx.refcount(&shared).await, Some(1), "still held by file b");
}

#[tokio::test]
async fn sweep_orphans_removes_refcount_0_chunks_past_the_grace_period_only() {
    let fx = fixture("gc3@example.com").await;
    let a = hex();
    let v1 = fx.commit("f", &[c(&a)]).await;
    fx.prune(&v1).await;
    fx.server
        .age_chunk(fx.user_id, &a, fx.now.minus_seconds(2 * HOUR))
        .await;

    let before = fx.server.chunk_rows(fx.user_id).await;
    assert_eq!(fx.sweep(HOUR).await, 1);
    assert_eq!(fx.server.chunk_rows(fx.user_id).await, before - 1);
    assert_eq!(fx.refcount(&a).await, None);
}

#[tokio::test]
async fn sweep_orphans_keeps_a_recently_zeroed_chunk_within_grace() {
    let fx = fixture("gc4@example.com").await;
    let a = hex();
    let v1 = fx.commit("f", &[c(&a)]).await;
    fx.prune(&v1).await; // refcount 0, touched just now

    assert_eq!(fx.sweep(HOUR).await, 0);
    assert_eq!(fx.refcount(&a).await, Some(0), "inside grace -> retained");
}

/// THE GRACE WINDOW'S ONLY REAL TEST. The sibling above cannot fail for the reason it exists: its
/// chunk was CREATED moments earlier, so `updated_at` is inside the window whether or not the
/// decrement moved it. This is the real shape — a chunk that has existed for hours (every chunk
/// in a real library) and was zeroed just now. A refcount write that leaves `updated_at` behind
/// makes the window measure creation age, and the sweep frees a chunk a concurrent commit could
/// still be deduping against.
#[tokio::test]
async fn sweep_orphans_keeps_a_chunk_zeroed_now_even_though_it_was_created_long_ago() {
    let fx = fixture("gc5@example.com").await;
    let a = hex();
    let v1 = fx.commit("f", &[c(&a)]).await;
    fx.server
        .age_chunk(fx.user_id, &a, fx.now.minus_seconds(3 * HOUR))
        .await;

    fx.prune(&v1).await; // zeroed NOW

    assert_eq!(fx.sweep(HOUR).await, 0);
    assert_eq!(
        fx.refcount(&a).await,
        Some(0),
        "the window must measure time since ZEROING, not since creation"
    );
}

/// A stand-in for the object store whose delete re-references the OTHER chunk of the pair — what
/// a concurrent finalize does when it dedups against a row that is still present (uploads
/// nothing, takes the refcount 0 -> 1). The second chunk is already in the sweep's loaded batch
/// by then, so only the `refcount <= 0` re-asserted inside the DELETE can save it.
struct Racer {
    db: Db,
    user_id: i64,
    a: String,
    b: String,
    now: Timestamp,
}

impl DeleteBytes for Racer {
    fn delete(&mut self, hash: &str) -> impl Future<Output = anyhow::Result<()>> + Send {
        let other = if hash == self.a {
            self.b.clone()
        } else {
            self.a.clone()
        };
        let mut db = self.db.clone();
        let (user_id, now) = (self.user_id, self.now);
        async move {
            touch_refcounts(&mut db, user_id, &[other], 1, now, false).await?;
            Ok(())
        }
    }
}

#[tokio::test]
async fn sweep_orphans_refuses_to_free_a_chunk_re_referenced_after_its_batch_was_read() {
    let fx = fixture("gc6@example.com").await;
    let (a, b) = (hex(), hex());
    let v1 = fx.commit("f", &[c(&a), c(&b)]).await;
    fx.prune(&v1).await;
    fx.server
        .age_all_chunks(fx.user_id, fx.now.minus_seconds(2 * HOUR))
        .await;

    let racer = Racer {
        db: fx.server.db.clone(),
        user_id: fx.user_id,
        a: a.clone(),
        b: b.clone(),
        now: fx.now,
    };
    gc::sweep_orphans_with(&fx.server.db, fx.user_id, HOUR, fx.now, racer)
        .await
        .expect("sweep");

    assert_eq!(
        fx.server.chunk_rows(fx.user_id).await,
        1,
        "the re-referenced chunk survives"
    );
    let survivor = if fx.refcount(&a).await.is_some() {
        &a
    } else {
        &b
    };
    assert_eq!(fx.refcount(survivor).await, Some(1));
}

#[tokio::test]
async fn prune_version_decrements_once_even_if_called_twice_for_the_same_version() {
    let fx = fixture("gc7@example.com").await;
    let shared = hex();
    let v1 = fx.commit("a", &[c(&shared)]).await;
    fx.commit("b", &[c(&shared)]).await;
    assert_eq!(fx.refcount(&shared).await, Some(2));

    assert!(fx.prune(&v1).await, "first call claims the version");
    assert!(!fx.prune(&v1).await, "second call finds nothing to claim");

    assert_eq!(
        fx.refcount(&shared).await,
        Some(1),
        "still held by file b -- a double decrement would zero a LIVE chunk"
    );
}

#[tokio::test]
async fn sweep_orphans_never_removes_a_live_chunk() {
    let fx = fixture("gc8@example.com").await;
    let a = hex();
    fx.commit("f", &[c(&a)]).await; // refcount 1
    fx.server
        .age_chunk(fx.user_id, &a, fx.now.minus_seconds(2 * HOUR))
        .await;

    assert_eq!(fx.sweep(HOUR).await, 0);
    assert_eq!(fx.refcount(&a).await, Some(1));
}

#[tokio::test]
async fn sweep_orphans_actually_deletes_the_bytes() {
    let fx = fixture("gc9@example.com").await;
    let a = hex();
    let v1 = fx.commit("f", &[c(&a)]).await;
    assert!(fx.exists(&a).await);

    fx.prune(&v1).await;
    fx.server
        .age_chunk(fx.user_id, &a, fx.now.minus_seconds(2 * HOUR))
        .await;
    fx.sweep(HOUR).await;

    assert_eq!(fx.refcount(&a).await, None, "row gone");
    assert!(!fx.exists(&a).await, "object deleted from storage");
}

struct Boom;

impl DeleteBytes for Boom {
    #[allow(clippy::manual_async_fn)]
    fn delete(&mut self, _hash: &str) -> impl Future<Output = anyhow::Result<()>> + Send {
        async { Err(anyhow::anyhow!("S3 unreachable")) }
    }
}

#[tokio::test]
async fn sweep_orphans_deletes_the_row_even_if_the_storage_delete_fails() {
    let fx = fixture("gc10@example.com").await;
    let a = hex();
    let v1 = fx.commit("f", &[c(&a)]).await;
    fx.prune(&v1).await;
    fx.server
        .age_chunk(fx.user_id, &a, fx.now.minus_seconds(2 * HOUR))
        .await;

    let swept = gc::sweep_orphans_with(&fx.server.db, fx.user_id, HOUR, fx.now, Boom)
        .await
        .expect("a storage failure never fails the sweep");
    assert_eq!(swept, 1);
    assert_eq!(fx.refcount(&a).await, None);
}

// ---- apply_retention ---------------------------------------------------------------------------

#[tokio::test]
async fn apply_retention_with_keep_all_prunes_nothing() {
    let fx = fixture("ret1@example.com").await;
    let nid = new_uuid();
    let vs = fx.make_history(&nid, &[60, 5 * DAY, 400 * DAY]).await;
    assert_eq!(fx.retain(Policy::KeepAll, 0).await, 0);
    for v in &vs {
        assert!(fx.server.version_exists(fx.user_id, &v.version_id).await);
    }
}

#[tokio::test]
async fn apply_retention_tiered_prunes_thinned_versions_but_never_current() {
    let fx = fixture("ret2@example.com").await;
    let nid = new_uuid();
    let vs = fx
        .make_history(&nid, &[60, 5 * DAY, 5 * DAY + HOUR, 5 * DAY + 2 * HOUR])
        .await;
    let current = vs.iter().max_by_key(|v| v.created_at).unwrap();

    assert_eq!(fx.retain(Policy::Tiered, 0).await, 2);

    let mut surviving = Vec::new();
    for v in &vs {
        if fx.server.version_exists(fx.user_id, &v.version_id).await {
            surviving.push(v.version_id.clone());
        }
    }
    assert!(
        surviving.contains(&current.version_id),
        "current is never pruned"
    );
    assert_eq!(surviving.len(), 2, "current + one daily survivor");
}

#[tokio::test]
async fn apply_retention_tiered_never_prunes_a_pinned_version() {
    let fx = fixture("ret3@example.com").await;
    let nid = new_uuid();
    let vs = fx
        .make_history(&nid, &[60, 200 * DAY, 200 * DAY + HOUR])
        .await;
    let current = vs.iter().max_by_key(|v| v.created_at).unwrap();
    let pinned = vs.iter().min_by_key(|v| v.created_at).unwrap();
    fx.server.pin_version(fx.user_id, &pinned.version_id).await;

    fx.retain(Policy::Tiered, 0).await;

    assert!(
        fx.server
            .version_exists(fx.user_id, &pinned.version_id)
            .await,
        "pinned survives"
    );
    assert!(
        fx.server
            .version_exists(fx.user_id, &current.version_id)
            .await
    );
}

#[tokio::test]
async fn apply_retention_tiered_frees_the_chunks_of_pruned_versions_from_storage() {
    let fx = fixture("ret4@example.com").await;
    let nid = new_uuid();
    let vs = fx.make_history(&nid, &[60, 5 * DAY, 5 * DAY + HOUR]).await;
    // Same-day pair {5d, 5d+1h}: tiered keeps the NEWEST (5d), thins the older (5d+1h).
    let pruned = vs.iter().min_by_key(|v| v.created_at).unwrap();
    let pruned_hash = fx.first_hash(pruned).await;
    assert!(fx.exists(&pruned_hash).await);

    fx.retain(Policy::Tiered, 0).await;

    assert!(
        !fx.server
            .version_exists(fx.user_id, &pruned.version_id)
            .await,
        "version pruned"
    );
    assert_eq!(fx.refcount(&pruned_hash).await, None, "chunk row gone");
    assert!(
        !fx.exists(&pruned_hash).await,
        "refcount-0 chunk deleted from storage"
    );
}

#[tokio::test]
async fn tiered_retention_keeps_a_version_an_unresolved_conflict_references_and_it_stays_resolvable()
 {
    let fx = fixture("ret5@example.com").await;
    let nid = new_uuid();
    let vs = fx.make_history(&nid, &[60, 5 * DAY, 5 * DAY + HOUR]).await;
    let would_prune = vs.iter().min_by_key(|v| v.created_at).unwrap();
    let current = vs.iter().max_by_key(|v| v.created_at).unwrap();
    let mut db = fx.server.db.clone();
    Conflict::record(
        &mut db,
        fx.user_id,
        &nid,
        &would_prune.version_id,
        &current.version_id,
        fx.now,
    )
    .await
    .expect("conflict");

    fx.retain(Policy::Tiered, 0).await;

    assert!(
        fx.server
            .version_exists(fx.user_id, &would_prune.version_id)
            .await,
        "a version referenced by an open conflict must not be pruned"
    );
    let h = fx.first_hash(would_prune).await;
    assert!(fx.refcount(&h).await.is_some(), "its chunks survive too");
    conflicts::keep(
        &fx.server.db,
        fx.user_id,
        &nid,
        &would_prune.version_id,
        fx.now,
    )
    .await
    .expect("still resolvable afterwards");
}

/// THE SHARE-LINK LINE'S ONLY GUARD. `gc::referenced_version_ids` reads `share_links`; delete that
/// loop and everything still compiles and runs, and nightly retention quietly prunes versions
/// that URLs already sent to other people still point at. `Tiered` on purpose: `KeepAll` never
/// prunes and would pass with or without the line.
#[tokio::test]
async fn tiered_retention_keeps_a_version_referenced_by_a_live_share_link() {
    let fx = fixture("ret6@example.com").await;
    let nid = new_uuid();
    let vs = fx.make_history(&nid, &[60, 5 * DAY, 5 * DAY + HOUR]).await;
    let shared = vs.iter().min_by_key(|v| v.created_at).unwrap();
    let mut db = fx.server.db.clone();
    ShareLink::create(
        &mut db,
        fx.user_id,
        &nid,
        &shared.version_id,
        &shared.manifest_id,
        &sha256_hex(b"some-token"),
        None,
        fx.now,
    )
    .await
    .expect("share link");

    fx.retain(Policy::Tiered, 0).await;

    assert!(
        fx.server
            .version_exists(fx.user_id, &shared.version_id)
            .await,
        "a live share link's frozen version must not be pruned"
    );
    let h = fx.first_hash(shared).await;
    assert!(
        fx.exists(&h).await,
        "its chunks survive (presigned GETs would otherwise dangle)"
    );
}

#[tokio::test]
async fn a_revoked_or_expired_share_link_protects_nothing() {
    let fx = fixture("ret7@example.com").await;
    let nid = new_uuid();
    let vs = fx.make_history(&nid, &[60, 5 * DAY, 5 * DAY + HOUR]).await;
    let thinned = vs.iter().min_by_key(|v| v.created_at).unwrap();
    let mut db = fx.server.db.clone();
    ShareLink::create(
        &mut db,
        fx.user_id,
        &nid,
        &thinned.version_id,
        &thinned.manifest_id,
        &sha256_hex(b"expired-token"),
        Some(fx.now.minus_seconds(DAY)),
        fx.now,
    )
    .await
    .expect("share link");

    assert_eq!(fx.retain(Policy::Tiered, 0).await, 1);
    assert!(
        !fx.server
            .version_exists(fx.user_id, &thinned.version_id)
            .await
    );
}

// ---- reap_storage (the list-based backstop) ----------------------------------------------------

#[tokio::test]
async fn reap_storage_reaps_a_leaked_object_with_no_row_past_the_grace_window() {
    let fx = fixture("rs1@example.com").await;
    let orphan = fx.upload(2 * HOUR).await;
    assert!(fx.exists(&orphan).await);

    let reaped = fx.reap_storage(HOUR, false).await;

    assert_eq!(reaped, vec![orphan.clone()]);
    assert!(
        !fx.exists(&orphan).await,
        "leaked object deleted from storage"
    );
}

#[tokio::test]
async fn reap_storage_never_reaps_an_object_backed_by_a_committed_row() {
    let fx = fixture("rs2@example.com").await;
    let a = hex();
    fx.commit("f", &[c(&a)]).await;
    fx.server
        .local_store()
        .set_mtime(fx.user_id, &a, fx.now.minus_seconds(2 * HOUR))
        .expect("mtime");

    let reaped = fx.reap_storage(HOUR, false).await;

    assert!(reaped.is_empty());
    assert!(fx.exists(&a).await, "committed chunk never touched");
    assert_eq!(fx.refcount(&a).await, Some(1));
}

#[tokio::test]
async fn reap_storage_never_reaps_an_object_an_in_flight_pending_commit_references() {
    let fx = fixture("rs3@example.com").await;
    let inflight = hex();
    fx.pending(&[c(&inflight)], 0).await;
    // An OLD object, but a live pending names it: protected regardless of age.
    fx.server
        .local_store()
        .set_mtime(fx.user_id, &inflight, fx.now.minus_seconds(5 * HOUR))
        .expect("mtime");

    let reaped = fx.reap_storage(HOUR, false).await;

    assert!(reaped.is_empty());
    assert!(fx.exists(&inflight).await);
}

#[tokio::test]
async fn reap_storage_leaves_an_orphan_younger_than_the_grace_window() {
    let fx = fixture("rs4@example.com").await;
    let fresh = fx.upload(10 * 60).await;
    let reaped = fx.reap_storage(HOUR, false).await;
    assert!(reaped.is_empty());
    assert!(
        fx.exists(&fresh).await,
        "young orphan retained (could be in-flight)"
    );
}

#[tokio::test]
async fn reap_storage_dry_run_reports_but_deletes_nothing() {
    let fx = fixture("rs5@example.com").await;
    let orphan = fx.upload(2 * HOUR).await;
    let would = fx.reap_storage(HOUR, true).await;
    assert_eq!(would, vec![orphan.clone()]);
    assert!(fx.exists(&orphan).await, "dry-run must not delete");
}

#[tokio::test]
async fn reap_storage_is_idempotent() {
    let fx = fixture("rs6@example.com").await;
    fx.upload(2 * HOUR).await;
    assert_eq!(fx.reap_storage(HOUR, false).await.len(), 1);
    assert!(
        fx.reap_storage(HOUR, false).await.is_empty(),
        "nothing left to reap"
    );
}

#[tokio::test]
async fn reap_storage_is_scoped_per_user() {
    let fx = fixture("rs7@example.com").await;
    let other = fx.server.issue_device("rs7-other@example.com", "o").await;
    let other_orphan = hex();
    fx.server
        .store()
        .put(other.user_id, &other_orphan, b"bytes")
        .await
        .expect("put");
    fx.server
        .local_store()
        .set_mtime(other.user_id, &other_orphan, fx.now.minus_seconds(2 * HOUR))
        .expect("mtime");

    let reaped = fx.reap_storage(HOUR, false).await;

    assert!(reaped.is_empty());
    assert!(
        fx.server
            .store()
            .exists(other.user_id, &other_orphan)
            .await
            .expect("exists"),
        "other user's object untouched"
    );
}

#[tokio::test]
async fn reap_storage_all_sweeps_every_user_and_counts() {
    let fx = fixture("rs8@example.com").await;
    fx.upload(2 * HOUR).await;
    let u2 = fx.server.issue_device("rs8-u2@example.com", "d").await;
    let o2 = hex();
    fx.server
        .store()
        .put(u2.user_id, &o2, b"bytes")
        .await
        .expect("put");
    fx.server
        .local_store()
        .set_mtime(u2.user_id, &o2, fx.now.minus_seconds(2 * HOUR))
        .expect("mtime");

    let total = reapers::reap_storage_all(&fx.server.db, fx.server.store(), HOUR, false, fx.now)
        .await
        .expect("reap all");
    assert_eq!(total, 2, "one orphan reaped per user");
}

// ---- reap_pending (the targeted hourly reaper) -------------------------------------------------

#[tokio::test]
async fn reap_pending_reaps_an_expired_pendings_orphans_and_destroys_the_row() {
    let fx = fixture("rp1@example.com").await;
    let (a, b) = (hex(), hex());
    let pc = fx.pending(&[c(&a), c(&b)], 25 * HOUR).await;
    assert!(fx.exists(&a).await && fx.exists(&b).await);

    let reaped = fx.reap_pending(DAY).await;

    assert!(reaped.contains(&a) && reaped.contains(&b));
    assert!(
        !fx.exists(&a).await && !fx.exists(&b).await,
        "orphan chunks deleted"
    );
    assert!(
        !fx.pending_row_exists(pc.id).await,
        "expired pending row destroyed"
    );
}

#[tokio::test]
async fn reap_pending_spares_a_chunk_a_committed_version_also_references() {
    let fx = fixture("rp2@example.com").await;
    let shared = hex();
    fx.commit("live", &[c(&shared)]).await;
    let pc = fx.pending(&[c(&shared)], 25 * HOUR).await;
    assert_eq!(fx.refcount(&shared).await, Some(1));

    let reaped = fx.reap_pending(DAY).await;

    assert!(reaped.is_empty());
    assert!(
        fx.exists(&shared).await,
        "deduped committed chunk never deleted"
    );
    assert!(
        !fx.pending_row_exists(pc.id).await,
        "expired row still destroyed"
    );
}

#[tokio::test]
async fn reap_pending_spares_a_chunk_another_live_pending_references() {
    let fx = fixture("rp3@example.com").await;
    let shared = hex();
    let expired = fx.pending(&[c(&shared)], 25 * HOUR).await;
    let _live = fx.pending(&[c(&shared)], 0).await;

    let reaped = fx.reap_pending(DAY).await;

    assert!(reaped.is_empty());
    assert!(
        fx.exists(&shared).await,
        "a chunk a live pending still needs is kept"
    );
    assert!(
        !fx.pending_row_exists(expired.id).await,
        "expired row destroyed"
    );
}

#[tokio::test]
async fn reap_pending_leaves_a_pending_that_has_not_expired_alone() {
    let fx = fixture("rp4@example.com").await;
    let a = hex();
    let pc = fx.pending(&[c(&a)], HOUR).await;

    let reaped = fx.reap_pending(DAY).await;

    assert!(reaped.is_empty());
    assert!(fx.exists(&a).await);
    assert!(
        fx.pending_row_exists(pc.id).await,
        "young pending row retained"
    );
}

#[tokio::test]
async fn reap_pending_is_idempotent() {
    let fx = fixture("rp5@example.com").await;
    fx.pending(&[c(&hex())], 25 * HOUR).await;
    assert_eq!(fx.reap_pending(DAY).await.len(), 1);
    assert!(
        fx.reap_pending(DAY).await.is_empty(),
        "nothing left to reap"
    );
}

/// A store whose delete fails once, for one hash, then behaves.
struct FailOnce<'s> {
    server: &'s TestServer,
    user_id: i64,
    fail_hash: String,
    failed: bool,
}

impl DeleteBytes for FailOnce<'_> {
    fn delete(&mut self, hash: &str) -> impl Future<Output = anyhow::Result<()>> + Send {
        let boom = hash == self.fail_hash && !self.failed;
        if boom {
            self.failed = true;
        }
        let store = self.server.store();
        let user_id = self.user_id;
        let hash = hash.to_string();
        async move {
            if boom {
                anyhow::bail!("boom: transient storage error");
            }
            store.delete(user_id, &hash).await
        }
    }
}

#[tokio::test]
async fn reap_pending_is_best_effort_on_a_storage_error() {
    let fx = fixture("rp6@example.com").await;
    let (a, b) = (hex(), hex());
    let pc = fx.pending(&[c(&a), c(&b)], 25 * HOUR).await;

    let deleter = FailOnce {
        server: &fx.server,
        user_id: fx.user_id,
        fail_hash: a.clone(),
        failed: false,
    };
    let reaped = reapers::reap_pending_with(
        &fx.server.db,
        fx.server.store(),
        fx.user_id,
        DAY,
        false,
        fx.now,
        deleter,
    )
    .await
    .expect("a storage error never fails the sweep");

    assert!(
        !reaped.contains(&a),
        "a failed delete is not reported as reaped"
    );
    assert!(reaped.contains(&b), "the rest of the sweep continued");
    assert!(!fx.exists(&b).await);
    assert!(
        !fx.pending_row_exists(pc.id).await,
        "row still destroyed despite the error"
    );
}

#[tokio::test]
async fn reap_pending_spares_a_chunk_whose_object_is_newer_than_the_cutoff() {
    let fx = fixture("rp7@example.com").await;
    let a = hex();
    let pc = fx.pending(&[c(&a)], 25 * HOUR).await;
    // A concurrent commit just re-uploaded the same content-addressed chunk: old row, fresh object.
    fx.server
        .local_store()
        .set_mtime(fx.user_id, &a, fx.now)
        .expect("mtime");

    let reaped = fx.reap_pending(DAY).await;

    assert!(
        reaped.is_empty(),
        "a fresh object must not be reaped (may be a live re-upload)"
    );
    assert!(fx.exists(&a).await);
    assert!(
        !fx.pending_row_exists(pc.id).await,
        "the expired row is still destroyed"
    );
}

#[tokio::test]
async fn reap_pending_is_scoped_per_user() {
    let fx = fixture("rp8@example.com").await;
    let other = fx.server.issue_device("rp8-other@example.com", "o").await;
    let other_hash = hex();
    let commit_id = fx
        .server
        .begin(
            other.user_id,
            other.device_id,
            &new_uuid(),
            "o",
            None,
            &[c(&other_hash)],
            fx.now,
        )
        .await;
    fx.server
        .age_pending(other.user_id, &commit_id, fx.now.minus_seconds(25 * HOUR))
        .await;

    let reaped = fx.reap_pending(DAY).await;

    assert!(reaped.is_empty());
    assert!(
        fx.server
            .store()
            .exists(other.user_id, &other_hash)
            .await
            .expect("exists"),
        "other tenant's object untouched"
    );
}

/// THE DIVERGENCE BETWEEN THE TWO GUARDS, pinned as a decision. `reap_storage` unions EVERY
/// pending row with no age filter; `reap_pending` excludes exactly the expired rows it is about
/// to destroy. One expired pending, one old object, and the two must answer DIFFERENTLY. Narrow
/// the storage reaper to match and the backstop deletes a live commit's chunk; widen this one to
/// match and it is a no-op.
#[tokio::test]
async fn an_expired_pendings_hash_is_protected_from_reap_storage_and_reaped_by_reap_pending() {
    let fx = fixture("rp9@example.com").await;
    let h = hex();
    let pc = fx.pending(&[c(&h)], 25 * HOUR).await;

    assert!(
        fx.reap_storage(HOUR, false).await.is_empty(),
        "reap-storage unions EVERY pending row -- an expired one still protects its hash"
    );
    assert!(fx.exists(&h).await, "reap-storage leaves it in storage");
    assert!(
        fx.pending_row_exists(pc.id).await,
        "reap-storage never destroys a pending row"
    );

    assert_eq!(
        fx.reap_pending(DAY).await,
        vec![h.clone()],
        "reap-pending excludes the rows it is destroying, so it CAN reclaim"
    );
    assert!(!fx.exists(&h).await);
    assert!(
        !fx.pending_row_exists(pc.id).await,
        "the expired row is destroyed on every path"
    );
}

#[tokio::test]
async fn reap_pending_all_sweeps_every_user_and_counts() {
    let fx = fixture("rp10@example.com").await;
    fx.pending(&[c(&hex())], 25 * HOUR).await;
    let u2 = fx.server.issue_device("rp10-u2@example.com", "d2").await;
    let h2 = hex();
    let cid2 = fx
        .server
        .begin(
            u2.user_id,
            u2.device_id,
            &new_uuid(),
            "x",
            None,
            &[c(&h2)],
            fx.now,
        )
        .await;
    fx.server
        .age_pending(u2.user_id, &cid2, fx.now.minus_seconds(25 * HOUR))
        .await;
    fx.server
        .local_store()
        .set_mtime(u2.user_id, &h2, fx.now.minus_seconds(25 * HOUR))
        .expect("mtime");

    let total = reapers::reap_pending_all(&fx.server.db, fx.server.store(), DAY, false, fx.now)
        .await
        .expect("reap all");
    assert_eq!(total, 2, "one orphan reaped per user");
}

/// The Ruby reaper once wedged on a pending row whose manifest entry had NO hash: the local
/// store's hash validation raised outside the reaper's rescue, the row survived, and the storage
/// reaper was blocked from those bytes forever. The door is where it is closed: a hashless entry
/// never becomes a pending row at all, so the ordinary expired row beside it reaps normally.
#[tokio::test]
async fn a_hashless_manifest_entry_is_refused_at_begin_so_the_wedge_cannot_form() {
    let fx = fixture("rp11@example.com").await;
    let bad = vec![serde_json::json!({ "offset": 0, "length": 5 })];
    let refused = commit::begin(
        &fx.server.db,
        fx.server.store(),
        &fx.server.base_url,
        fx.user_id,
        BeginParams {
            commit_id: Some(new_uuid()),
            node_id: Some(new_uuid()),
            parent_node_id: None,
            name: Some("bad.bin".into()),
            base_version_id: None,
            size: 5,
            mode: None,
            mtime: None,
            manifest: &bad,
            device_id: Some(fx.device_id),
        },
        fx.now,
    )
    .await;
    assert!(
        matches!(refused, Err(ApiError::Unprocessable(_))),
        "{refused:?}"
    );
    assert_eq!(
        fx.server.pending_rows(fx.user_id).await,
        0,
        "nothing was staged"
    );

    let good = hex();
    fx.pending(&[c(&good)], 25 * HOUR).await;

    assert_eq!(fx.reap_pending(DAY).await, vec![good.clone()]);
    assert!(!fx.exists(&good).await);
    assert_eq!(
        fx.server.pending_rows(fx.user_id).await,
        0,
        "no row survives to block reap-storage"
    );
    assert!(
        !reapers::pending_hashes(&fx.server.db, fx.user_id)
            .await
            .expect("pending hashes")
            .contains(&good)
    );
}
