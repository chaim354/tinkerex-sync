//! Chunk garbage collection (`Sync::Gc`). Refcounts count the live versions referencing a chunk;
//! a NODE delete only tombstones (versions and their chunks stay so restore works), so chunks are
//! freed only when a VERSION is pruned by retention and its chunks reach refcount 0, which the
//! sweep collects past a grace window.
//!
//! Three orderings are load-bearing, and each cost the Ruby engine a silent data-loss bug
//! (CLAUDE.md §4b):
//!   - `prune_version` is CLAIM-THEN-DECREMENT under the user lock: the version row's delete is
//!     the claim, so of two overlapping retention passes exactly one removes 1 row and decrements;
//!     the user lock serializes it against the seq-writers (a restore re-referencing the very
//!     chunks being zeroed).
//!   - every refcount write goes through `models::touch_refcounts`, which moves `updated_at` —
//!     the sweep's grace window measures time since ZEROING, never since creation.
//!   - `sweep_orphans` takes no user lock, so its batch is a snapshot a concurrent finalize can
//!     re-reference 0 -> 1 while uploading nothing; the DELETE re-asserts `refcount <= 0`
//!     (compare-and-swap) and the row goes before the bytes, so a storage failure orphans bytes
//!     at worst, never a live version.

use std::collections::HashSet;

use crate::db::Db;
use crate::error::ApiResult;
use crate::models::{
    ChangelogEntry, Conflict, Node, ShareLink, Version, delete_chunk_if_zero, manifest_hashes,
    touch_refcounts, zeroed_chunks_before,
};
use crate::services::mutation::UserLock;
use crate::services::retention::Policy;
use crate::store::ChunkStore;
use crate::time::Timestamp;

/// The default grace before a zeroed chunk's bytes are collected.
pub const DEFAULT_GRACE_SECS: i64 = 3600;

/// Decrement a version's chunks and delete the version. `true` when THIS call pruned it, `false`
/// when an overlapping pass already had — and only the claimant decrements.
pub async fn prune_version(
    db: &Db,
    user_id: i64,
    version: &Version,
    now: Timestamp,
) -> ApiResult<bool> {
    let mut lock = UserLock::begin(db, user_id).await?;
    let claimed =
        Version::delete_by_version_id(lock.tx(), user_id, &version.version_id).await? == 1;
    if !claimed {
        lock.commit().await?;
        return Ok(false);
    }
    let hashes = manifest_hashes(lock.tx(), user_id, &version.manifest_id).await?;
    if !hashes.is_empty() {
        touch_refcounts(lock.tx(), user_id, &hashes, -1, now, true).await?;
    }
    lock.commit().await?;
    Ok(true)
}

/// Every version_id a retention pass must protect beyond the policy's keep-set: both sides of
/// each unresolved conflict (resolution re-reads them) and every LIVE share link's version
/// (its presigned GETs would otherwise dangle).
///
/// THE SHARE-LINK LINE IS THE ONE THAT NOTHING BUT A TEST CAN MISS. Delete it and everything
/// still compiles and runs; the nightly pass then quietly prunes versions that URLs already sent
/// to other people still point at. `tests/gc.rs` pins it with the tiered policy, because
/// `keep_all` would pass with or without the line.
pub async fn referenced_version_ids(
    db: &Db,
    user_id: i64,
    now: Timestamp,
) -> ApiResult<HashSet<String>> {
    let mut dbh = db.clone();
    let mut ids = HashSet::new();
    for c in Conflict::unresolved_all(&mut dbh, user_id).await? {
        if !c.incoming_version_id.is_empty() {
            ids.insert(c.incoming_version_id);
        }
        if !c.current_version_id.is_empty() {
            ids.insert(c.current_version_id);
        }
    }
    for link in ShareLink::all_for_user(&mut dbh, user_id).await? {
        if link.live(now) && !link.version_id.is_empty() {
            ids.insert(link.version_id);
        }
    }
    Ok(ids)
}

/// Apply a policy across one user's library, then sweep freed chunks. Returns the number of
/// versions pruned — CLAIMS, not attempts (an overlapping pass's loser prunes nothing and does not
/// report that it did). `dry_run` counts what would be pruned and touches nothing, sweep included.
pub async fn apply_retention(
    db: &Db,
    store: &ChunkStore,
    user_id: i64,
    policy: Policy,
    grace_secs: i64,
    dry_run: bool,
    now: Timestamp,
) -> ApiResult<u64> {
    let mut dbh = db.clone();
    let referenced = referenced_version_ids(db, user_id, now).await?;
    let mut pruned = 0u64;
    for node_id in Version::node_ids_with_versions(&mut dbh, user_id).await? {
        let node = Node::find(&mut dbh, user_id, &node_id).await?;
        let versions = Version::all_for_node(&mut dbh, user_id, &node_id).await?;
        let current = node.as_ref().and_then(|n| n.current_version_id.as_deref());
        let keep = policy.keep_set(&versions, current, now);
        for v in &versions {
            if keep.contains(&v.version_id) || referenced.contains(&v.version_id) {
                continue;
            }
            // Counts CLAIMS, not attempts; a dry run counts what it would have claimed.
            if dry_run || prune_version(db, user_id, v, now).await? {
                pruned += 1;
            }
        }
    }
    if !dry_run {
        sweep_orphans(db, store, user_id, grace_secs, now).await?;
    }
    Ok(pruned)
}

/// Where a chunk's bytes go once its row is gone: the object store in production, a stand-in
/// (a racing bumper, a failing store) in a test.
pub trait DeleteBytes: Send {
    fn delete(
        &mut self,
        hash: &str,
    ) -> impl std::future::Future<Output = anyhow::Result<()>> + Send;
}

pub struct StoreDeleter<'s> {
    pub store: &'s ChunkStore,
    pub user_id: i64,
}

impl DeleteBytes for StoreDeleter<'_> {
    fn delete(
        &mut self,
        hash: &str,
    ) -> impl std::future::Future<Output = anyhow::Result<()>> + Send {
        self.store.delete(self.user_id, hash)
    }
}

/// Delete chunk rows at refcount 0 past `grace_secs`, then their bytes. Returns how many rows
/// went. `<=` on the cutoff so a grace of 0 means "sweep now" deterministically.
pub async fn sweep_orphans(
    db: &Db,
    store: &ChunkStore,
    user_id: i64,
    grace_secs: i64,
    now: Timestamp,
) -> ApiResult<u64> {
    sweep_orphans_with(
        db,
        user_id,
        grace_secs,
        now,
        StoreDeleter { store, user_id },
    )
    .await
}

/// The sweep with the byte delete injected, so a test can stand a racing bumper or a failing
/// store where the object store would be. Order per chunk: the ROW first (compare-and-swap), the
/// BYTES second and best-effort — a storage error is logged and the sweep continues, because the
/// row is what says a chunk is live and a later sweep re-deletes bytes harmlessly.
pub async fn sweep_orphans_with<D: DeleteBytes>(
    db: &Db,
    user_id: i64,
    grace_secs: i64,
    now: Timestamp,
    mut delete_bytes: D,
) -> ApiResult<u64> {
    let mut dbh = db.clone();
    let cutoff = now.minus_seconds(grace_secs);
    let batch = zeroed_chunks_before(&mut dbh, user_id, cutoff).await?;
    let mut swept = 0u64;
    for chunk in batch {
        // The row is the claim: lost the race (re-referenced since the batch was read) -> keep bytes.
        if delete_chunk_if_zero(&mut dbh, chunk.id).await? != 1 {
            continue;
        }
        swept += 1;
        if let Err(e) = delete_bytes.delete(&chunk.chunk_hash).await {
            tracing::warn!(
                user_id,
                hash = %chunk.chunk_hash,
                error = %e,
                "gc: storage delete failed after the row was removed; a later sweep reclaims the bytes"
            );
        }
    }
    Ok(swept)
}

/// Prune changelog history at or below `keep_after`. A device whose cursor is below the new floor
/// full-resyncs from the snapshot (`/v1/changes` reports `oldest_seq`). Never in the write path.
pub async fn prune_changelog(db: &Db, user_id: i64, keep_after: i64) -> ApiResult<u64> {
    let mut dbh = db.clone();
    Ok(ChangelogEntry::prune_through(&mut dbh, user_id, keep_after).await?)
}
