//! The two orphaned-BYTES reapers, for the leak `gc::sweep_orphans` cannot see: a commit that
//! uploaded chunk bytes over a presigned PUT and never finalized leaves objects in storage with no
//! `chunks` row at all. On R2 those bytes cost money forever.
//!
//! `reap_storage` (Ruby's `Sync::ChunkReaper`, G4) LISTS the user's keyspace — billed per request
//! on S3/R2, so it is the weekly backstop — and deletes an object only when no committed row
//! names its hash, no pending commit AT ALL names it (every row, no age filter: the backstop must
//! be the wider guard), and the object is older than the grace window.
//!
//! `reap_pending` (Ruby's `Sync::PendingCommitReaper`) does no list at all: an EXPIRED pending row
//! already names exactly the hashes it uploaded, so it deletes those (DB read + targeted deletes),
//! which is cheap enough to run hourly. Its live-pending guard is deliberately NARROWER — it
//! excludes the expired rows it is destroying, which is the only reason it can reclaim anything.
//! Narrow the storage reaper to match and the backstop deletes a chunk a slow live commit is
//! about to finalize; widen this one to match and it is a no-op. `tests/gc.rs` pins the
//! divergence in both directions. The expired rows are destroyed on EVERY path (reap or not, a
//! storage error or not): while one survives, the storage reaper's every-row guard protects
//! precisely the bytes it exists to reclaim.

use std::collections::{BTreeSet, HashSet};

use crate::db::Db;
use crate::error::ApiResult;
use crate::models::{PendingCommit, User, known_chunk_hashes};
use crate::services::gc::{DeleteBytes, StoreDeleter};
use crate::store::ChunkStore;
use crate::time::Timestamp;

/// The longest a legitimate un-finalized commit should live. Shared by both reapers so the two
/// windows cannot drift — but they ask different questions with it (an object's age here, a
/// pending ROW's age there).
pub const PENDING_COMMIT_TTL_SECS: i64 = 24 * 3600;

/// Every chunk hash any of the user's pending commits names, with NO age filter (see the module
/// doc for why that is the backstop's whole point). An unparseable manifest is skipped with a
/// warning rather than aborting the sweep.
pub async fn pending_hashes(db: &Db, user_id: i64) -> ApiResult<HashSet<String>> {
    let mut dbh = db.clone();
    let mut set = HashSet::new();
    for pc in PendingCommit::all_for_user(&mut dbh, user_id).await? {
        match pc.manifest() {
            Ok(refs) => set.extend(refs.into_iter().map(|c| c.hash)),
            Err(e) => tracing::warn!(user_id, commit_id = %pc.commit_id, error = %e,
                "reap-storage: skipping an unparseable pending manifest"),
        }
    }
    Ok(set)
}

/// Reap one user's leaked objects. Returns the hashes reaped (or, dry-run, those that would be).
pub async fn reap_storage(
    db: &Db,
    store: &ChunkStore,
    user_id: i64,
    grace_secs: i64,
    dry_run: bool,
    now: Timestamp,
) -> ApiResult<Vec<String>> {
    let objects = store.list(user_id).await?;
    if objects.is_empty() {
        return Ok(Vec::new());
    }
    let mut dbh = db.clone();
    let cutoff = now.minus_seconds(grace_secs);
    let hashes: Vec<String> = objects.iter().map(|o| o.hash.clone()).collect();
    let committed = known_chunk_hashes(&mut dbh, user_id, &hashes).await?;
    let pending = pending_hashes(db, user_id).await?;

    let mut reaped = Vec::new();
    for obj in objects {
        if committed.contains(&obj.hash) || pending.contains(&obj.hash) {
            continue;
        }
        if obj.last_modified.is_some_and(|lm| lm > cutoff) {
            continue; // within grace: maybe mid-commit
        }
        if !dry_run && let Err(e) = store.delete(user_id, &obj.hash).await {
            tracing::warn!(user_id, hash = %obj.hash, error = %e,
                "reap-storage: storage delete failed; reclaimed on a later run");
            continue;
        }
        reaped.push(obj.hash);
    }
    if !reaped.is_empty() {
        tracing::info!(
            user_id,
            count = reaped.len(),
            dry_run,
            "reap-storage: orphan chunk(s)"
        );
    }
    Ok(reaped)
}

/// Reap the orphaned chunks of one user's EXPIRED pending commits and destroy those rows.
pub async fn reap_pending(
    db: &Db,
    store: &ChunkStore,
    user_id: i64,
    ttl_secs: i64,
    dry_run: bool,
    now: Timestamp,
) -> ApiResult<Vec<String>> {
    reap_pending_with(
        db,
        store,
        user_id,
        ttl_secs,
        dry_run,
        now,
        StoreDeleter { store, user_id },
    )
    .await
}

/// `reap_pending` with the byte delete injected (a test stands a failing store there).
#[allow(clippy::too_many_arguments)]
pub async fn reap_pending_with<D: DeleteBytes>(
    db: &Db,
    store: &ChunkStore,
    user_id: i64,
    ttl_secs: i64,
    dry_run: bool,
    now: Timestamp,
    mut delete_bytes: D,
) -> ApiResult<Vec<String>> {
    let mut dbh = db.clone();
    let cutoff = now.minus_seconds(ttl_secs);
    let expired = PendingCommit::created_before(&mut dbh, user_id, cutoff).await?;
    if expired.is_empty() {
        return Ok(Vec::new());
    }
    let expired_ids: Vec<i64> = expired.iter().map(|pc| pc.id).collect();

    // Candidates: every hash any EXPIRED pending uploaded. Ordered, so a run is deterministic.
    let mut candidates = BTreeSet::new();
    for pc in &expired {
        candidates.extend(manifest_hashes_of(pc, user_id));
    }
    let candidate_list: Vec<String> = candidates.iter().cloned().collect();

    // Guards: a committed row owns it (dedup); a NON-expired pending is about to finalize it.
    let committed = if candidate_list.is_empty() {
        HashSet::new()
    } else {
        known_chunk_hashes(&mut dbh, user_id, &candidate_list).await?
    };
    let mut live_pending: HashSet<String> = HashSet::new();
    for pc in PendingCommit::created_at_or_after(&mut dbh, user_id, cutoff).await? {
        if expired_ids.contains(&pc.id) {
            continue;
        }
        live_pending.extend(manifest_hashes_of(&pc, user_id));
    }

    let mut reaped = Vec::new();
    for hash in candidate_list {
        if committed.contains(&hash) || live_pending.contains(&hash) {
            continue;
        }
        // Storage-age guard: the same content-addressed key may have just been RE-uploaded by a
        // fresh commit whose begin/finalize the snapshots above missed. A fresh object is live.
        if store
            .last_modified(user_id, &hash)
            .await?
            .is_some_and(|lm| lm > cutoff)
        {
            continue;
        }
        if !dry_run && let Err(e) = delete_bytes.delete(&hash).await {
            tracing::warn!(user_id, %hash, error = %e,
                "reap-pending: storage delete failed; the storage reaper reclaims it later");
            continue;
        }
        reaped.push(hash);
    }

    // The rows go regardless of per-hash outcomes: the row is what marks the commit abandoned,
    // and a surviving one blocks the storage reaper from these very bytes forever.
    if !dry_run {
        PendingCommit::delete_ids(&mut dbh, &expired_ids).await?;
    }
    if !reaped.is_empty() {
        tracing::info!(
            user_id,
            count = reaped.len(),
            expired = expired.len(),
            dry_run,
            "reap-pending: orphan chunk(s) from expired pending commit(s)"
        );
    }
    Ok(reaped)
}

fn manifest_hashes_of(pc: &PendingCommit, user_id: i64) -> Vec<String> {
    match pc.manifest() {
        Ok(refs) => refs.into_iter().map(|c| c.hash).collect(),
        Err(e) => {
            tracing::warn!(user_id, commit_id = %pc.commit_id, error = %e,
                "reap-pending: skipping an unparseable pending manifest");
            Vec::new()
        }
    }
}

/// Every user, one user's failure logged and isolated from the rest. Returns the total reaped.
pub async fn reap_storage_all(
    db: &Db,
    store: &ChunkStore,
    grace_secs: i64,
    dry_run: bool,
    now: Timestamp,
) -> ApiResult<usize> {
    let mut dbh = db.clone();
    let mut total = 0;
    for user_id in User::all_ids(&mut dbh).await? {
        match reap_storage(db, store, user_id, grace_secs, dry_run, now).await {
            Ok(reaped) => total += reaped.len(),
            Err(e) => tracing::error!(user_id, error = %e, "reap-storage failed for user"),
        }
    }
    Ok(total)
}

pub async fn reap_pending_all(
    db: &Db,
    store: &ChunkStore,
    ttl_secs: i64,
    dry_run: bool,
    now: Timestamp,
) -> ApiResult<usize> {
    let mut dbh = db.clone();
    let mut total = 0;
    for user_id in User::all_ids(&mut dbh).await? {
        match reap_pending(db, store, user_id, ttl_secs, dry_run, now).await {
            Ok(reaped) => total += reaped.len(),
            Err(e) => tracing::error!(user_id, error = %e, "reap-pending failed for user"),
        }
    }
    Ok(total)
}
