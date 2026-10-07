//! The two-phase content commit: `begin` stages the commit, reports the chunks the store is
//! missing and presigns their uploads; `finalize` atomically creates the immutable version,
//! updates the node and appends the changelog — detecting a divergent base as a conflict rather
//! than silently overwriting.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde::Serialize;
use serde_json::Value;

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::ids::{is_chunk_hash, manifest_id, new_uuid};
use crate::models::{
    ChunkRef, KIND_FILE, Node, PendingCommit, PendingFields, Version, insert_chunks,
    insert_manifest, known_chunk_hashes, manifest_exists, touch_refcounts,
};
use crate::store::ChunkStore;
use crate::time::Timestamp;

use super::mutation::UserWrite;
use super::nodes::{OP_CONFLICT, OP_PUT};
use super::params::{opt_str, opt_to_i, ruby_inspect, to_i};

/// Upper bound on manifest size — a ~100 GiB file at FastCDC's default target.
pub const MAX_MANIFEST_CHUNKS: usize = 100_000;

pub struct BeginParams<'a> {
    pub commit_id: Option<String>,
    pub node_id: Option<String>,
    pub parent_node_id: Option<String>,
    pub name: Option<String>,
    pub base_version_id: Option<String>,
    pub size: i64,
    pub mode: Option<i64>,
    pub mtime: Option<i64>,
    /// The raw `manifest` array as sent; normalized here exactly as Rails normalized it.
    pub manifest: &'a [Value],
    pub device_id: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct Begun {
    pub commit_id: String,
    pub missing: Vec<String>,
    pub put_urls: BTreeMap<String, String>,
}

/// `Sync::Commit.normalize`: `{hash, offset, length}` per entry, `offset`/`length` via `to_i`,
/// `hash` kept as whatever was sent so the validation below can name it.
fn normalize(manifest: &[Value]) -> Vec<(Option<&Value>, i64, i64)> {
    manifest
        .iter()
        .map(|c| match c {
            Value::Object(m) => (m.get("hash"), to_i(m.get("offset")), to_i(m.get("length"))),
            _ => (None, 0, 0),
        })
        .collect()
}

pub async fn begin(
    db: &Db,
    store: &ChunkStore,
    base_url: &str,
    user_id: i64,
    p: BeginParams<'_>,
    now: Timestamp,
) -> ApiResult<Begun> {
    let entries = normalize(p.manifest);
    if entries.len() > MAX_MANIFEST_CHUNKS {
        return Err(ApiError::Unprocessable(format!(
            "manifest too large ({} > {MAX_MANIFEST_CHUNKS})",
            entries.len()
        )));
    }
    let bad: Vec<String> = entries
        .iter()
        .map(|(h, _, _)| *h)
        .filter(|h| !matches!(h, Some(Value::String(s)) if is_chunk_hash(s)))
        .take(3)
        .map(ruby_inspect)
        .collect();
    if !bad.is_empty() {
        return Err(ApiError::Unprocessable(format!(
            "invalid chunk hash(es): {}",
            bad.join(", ")
        )));
    }
    let refs: Vec<ChunkRef> = entries
        .iter()
        .map(|(h, offset, length)| ChunkRef {
            hash: h.and_then(Value::as_str).unwrap_or_default().to_string(),
            offset: *offset,
            length: *length,
        })
        .collect();
    let mid = manifest_id(refs.iter().map(|c| c.hash.as_str()));
    let mut hashes: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for c in &refs {
        if seen.insert(c.hash.clone()) {
            hashes.push(c.hash.clone());
        }
    }

    // Active Record's presence validations on the staging row, in declaration order.
    let mut blank = Vec::new();
    for (value, label) in [
        (&p.commit_id, "Commit"),
        (&p.node_id, "Node"),
        (&p.name, "Name"),
    ] {
        if value
            .as_deref()
            .map(|s| s.trim().is_empty())
            .unwrap_or(true)
        {
            blank.push(format!("{label} can't be blank"));
        }
    }
    if !blank.is_empty() {
        return Err(ApiError::Unprocessable(format!(
            "Validation failed: {}",
            blank.join(", ")
        )));
    }
    let commit_id = p.commit_id.unwrap_or_default();
    let manifest_json = serde_json::to_string(&refs).map_err(|e| ApiError::Internal(e.into()))?;
    let mut dbh = db.clone();
    PendingCommit::upsert(
        &mut dbh,
        user_id,
        &commit_id,
        &PendingFields {
            node_id: p.node_id.as_deref().unwrap_or_default(),
            parent_node_id: p.parent_node_id.as_deref(),
            name: p.name.as_deref().unwrap_or_default(),
            manifest_id: &mid,
            manifest_json: &manifest_json,
            base_version_id: p.base_version_id.as_deref(),
            size: p.size,
            mode: p.mode,
            mtime: p.mtime,
            device_id: p.device_id,
        },
        now,
    )
    .await?;

    let present = known_chunk_hashes(&mut dbh, user_id, &hashes).await?;
    let missing: Vec<String> = hashes
        .into_iter()
        .filter(|h| !present.contains(h))
        .collect();
    let mut put_urls = BTreeMap::new();
    for h in &missing {
        put_urls.insert(
            h.clone(),
            store.presign_put(base_url, user_id, h, now).await?,
        );
    }
    Ok(Begun {
        commit_id,
        missing,
        put_urls,
    })
}

/// The request-body reading of `begin`'s parameters, with Rails' coercions.
pub fn begin_params_from(
    body: &serde_json::Map<String, Value>,
    device_id: Option<i64>,
) -> BeginParams<'_> {
    static EMPTY: Vec<Value> = Vec::new();
    BeginParams {
        commit_id: opt_str(body.get("commit_id")),
        node_id: opt_str(body.get("node_id")),
        parent_node_id: opt_str(body.get("parent_node_id")),
        name: opt_str(body.get("name")),
        base_version_id: opt_str(body.get("base_version_id")),
        size: to_i(body.get("size")),
        mode: opt_to_i(body.get("mode")),
        mtime: opt_to_i(body.get("mtime")),
        manifest: body
            .get("manifest")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&EMPTY),
        device_id,
    }
}

pub struct Finalized {
    pub version: Version,
    pub seq: i64,
}

pub async fn finalize(
    db: &Db,
    store: &ChunkStore,
    user_id: i64,
    commit_id: &str,
    verify: bool,
    now: Timestamp,
) -> ApiResult<Finalized> {
    let mut dbh = db.clone();
    let pending = PendingCommit::find(&mut dbh, user_id, commit_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let manifest = pending.manifest().map_err(|e| {
        ApiError::Internal(anyhow::anyhow!(
            "pending commit {commit_id} carries an unparseable manifest: {e}"
        ))
    })?;
    let mut hashes: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for c in &manifest {
        if seen.insert(c.hash.clone()) {
            hashes.push(c.hash.clone());
        }
    }

    if verify {
        // HEAD only what the database does not already know, and ask it once, not per hash.
        let known = known_chunk_hashes(&mut dbh, user_id, &hashes).await?;
        let mut missing = Vec::new();
        for h in &hashes {
            if !known.contains(h) && !store.exists(user_id, h).await? {
                missing.push(h.clone());
            }
        }
        if !missing.is_empty() {
            return Err(ApiError::ChunksMissing(missing));
        }
    }

    let mut w = UserWrite::begin(db, user_id).await?;
    let seq = w.seq();

    if !manifest_exists(w.tx(), user_id, &pending.manifest_id).await? {
        insert_manifest(w.tx(), user_id, &pending.manifest_id, &manifest).await?;
    }
    upsert_chunks(&mut w, user_id, &manifest, now).await?;

    let mut node = Node::find(w.tx(), user_id, &pending.node_id)
        .await?
        .unwrap_or_else(|| Node::new(user_id, &pending.node_id, now));
    if node.persisted() && node.kind != KIND_FILE {
        let msg = format!(
            "node {} already exists as a {}, cannot become a file",
            pending.node_id, node.kind
        );
        w.rollback().await?;
        return Err(ApiError::Conflict(msg));
    }
    let prior_current = node.current_version_id.clone();
    node.parent_node_id = pending.parent_node_id.clone();
    node.name = pending.name.clone();
    node.kind = KIND_FILE.to_string();
    node.deleted = false;
    node.mode = Some(pending.mode.or(node.mode).unwrap_or(0o644));
    node.mtime = pending.mtime.or(node.mtime);

    let mut version = Version {
        id: None,
        user_id,
        version_id: new_uuid(),
        node_id: pending.node_id.clone(),
        manifest_id: pending.manifest_id.clone(),
        size: pending.size,
        device_id: pending.device_id,
        parent_version_id: pending.base_version_id.clone(),
        pinned: false,
        created_at: now,
    };
    version.insert(w.tx()).await?;

    // Conflict iff the client based this edit on a version that is no longer current...
    let base = pending
        .base_version_id
        .as_deref()
        .filter(|b| !b.trim().is_empty());
    let mut is_conflict = matches!((node.persisted(), prior_current.as_deref(), base), (true, Some(prior), Some(b)) if prior != b);
    // ...but a divergence from the SAME device is that device racing its own echo, not a conflict.
    if let (true, Some(_), Some(prior)) = (is_conflict, pending.device_id, prior_current.as_deref())
    {
        let prior_version = Version::find(w.tx(), user_id, prior).await?;
        if prior_version
            .map(|v| v.device_id == pending.device_id)
            .unwrap_or(false)
        {
            is_conflict = false;
        }
    }

    let op = if is_conflict {
        let prior = prior_current.clone().unwrap_or_default();
        crate::models::Conflict::record(
            w.tx(),
            user_id,
            &pending.node_id,
            &version.version_id,
            &prior,
            now,
        )
        .await?;
        OP_CONFLICT
    } else {
        node.current_version_id = Some(version.version_id.clone());
        OP_PUT
    };

    node.updated_seq = seq;
    node.save(w.tx(), now).await?;
    w.append(seq, &pending.node_id, op, Some(&version.version_id), now)
        .await?;
    PendingCommit::delete(w.tx(), pending.id).await?;
    w.commit().await?;
    Ok(Finalized { version, seq })
}

/// One refcount per unique chunk per version: new chunks at 1 (sized by the LAST manifest entry
/// naming them, as Rails' hash overwrite did), existing ones +1 through the one touch function.
async fn upsert_chunks(
    w: &mut UserWrite,
    user_id: i64,
    manifest: &[ChunkRef],
    now: Timestamp,
) -> ApiResult<()> {
    let mut sizes: HashMap<String, i64> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for c in manifest {
        if !sizes.contains_key(&c.hash) {
            order.push(c.hash.clone());
        }
        sizes.insert(c.hash.clone(), c.length);
    }
    let existing = known_chunk_hashes(w.tx(), user_id, &order).await?;
    let new_rows: Vec<(String, i64)> = order
        .iter()
        .filter(|h| !existing.contains(*h))
        .map(|h| (h.clone(), sizes[h]))
        .collect();
    if !new_rows.is_empty() {
        insert_chunks(w.tx(), user_id, &new_rows, now).await?;
    }
    let existing_list: Vec<String> = order
        .iter()
        .filter(|h| existing.contains(*h))
        .cloned()
        .collect();
    if !existing_list.is_empty() {
        touch_refcounts(w.tx(), user_id, &existing_list, 1, now, false).await?;
    }
    Ok(())
}
