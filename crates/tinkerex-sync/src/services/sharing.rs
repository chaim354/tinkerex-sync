//! Read-only share links: a capability token over ONE immutable version. A redeemed link mints
//! presigned GETs against the OWNER's keyspace for exactly that version's manifest chunks — the
//! hash set is fixed at creation by the frozen manifest, so a link can never address anything
//! else. Liveness (not revoked, not expired) is re-evaluated on every request.

use std::collections::{BTreeMap, HashSet};

use serde::Serialize;

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::ids::{new_token, sha256_hex};
use crate::models::{ChunkRef, Node, ShareLink, Version, load_manifests, manifest_hash_set};
use crate::store::ChunkStore;
use crate::time::Timestamp;

pub struct Created {
    pub id: i64,
    pub token: String,
    pub version_id: String,
    pub expires_at: Option<Timestamp>,
}

/// `POST /v1/share_links`: the version must belong to the caller AND to the named node.
pub async fn create_for_version(
    db: &Db,
    user_id: i64,
    node_id: &str,
    version_id: &str,
    expires_at: Option<Timestamp>,
    now: Timestamp,
) -> ApiResult<Created> {
    let mut db = db.clone();
    let version = Version::find_for_node(&mut db, user_id, version_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let raw = new_token();
    let link = ShareLink::create(
        &mut db,
        user_id,
        node_id,
        version_id,
        &version.manifest_id,
        &sha256_hex(raw.as_bytes()),
        expires_at,
        now,
    )
    .await?;
    Ok(Created {
        id: link.id,
        token: raw,
        version_id: link.version_id,
        expires_at: link.expires_at,
    })
}

/// `DELETE /v1/share_links/:id`, scoped to the caller's own links (another user's id is a 404).
pub async fn revoke(db: &Db, user_id: i64, id: i64, now: Timestamp) -> ApiResult<()> {
    let mut db = db.clone();
    let link = ShareLink::find_owned(&mut db, user_id, id)
        .await?
        .ok_or(ApiError::NotFound)?;
    ShareLink::revoke(&mut db, link.id, now).await?;
    Ok(())
}

/// A read-only capability over one immutable version. Never a session; cannot be promoted.
pub struct Capability {
    pub owner_id: i64,
    pub node_id: String,
    pub version_id: String,
    pub manifest_id: String,
    pub chunk_hashes: HashSet<String>,
}

/// `None` for an unknown, expired or revoked token — the anonymous side never learns which.
pub async fn redeem(db: &Db, raw: &str, now: Timestamp) -> ApiResult<Option<Capability>> {
    let mut db = db.clone();
    let Some(link) = ShareLink::find_by_digest(&mut db, &sha256_hex(raw.as_bytes())).await? else {
        return Ok(None);
    };
    if !link.live(now) {
        return Ok(None);
    }
    let chunk_hashes = manifest_hash_set(&mut db, link.user_id, &link.manifest_id).await?;
    Ok(Some(Capability {
        owner_id: link.user_id,
        node_id: link.node_id,
        version_id: link.version_id,
        manifest_id: link.manifest_id,
        chunk_hashes,
    }))
}

#[derive(Debug, Serialize)]
pub struct Shown {
    pub name: Option<String>,
    pub node_id: String,
    pub version_id: String,
    pub manifest: Vec<ChunkRef>,
}

pub async fn show(db: &Db, cap: &Capability) -> ApiResult<Shown> {
    let mut db = db.clone();
    let node = Node::find(&mut db, cap.owner_id, &cap.node_id).await?;
    let manifest = load_manifests(
        &mut db,
        cap.owner_id,
        std::slice::from_ref(&cap.manifest_id),
    )
    .await?
    .remove(&cap.manifest_id)
    .unwrap_or_default();
    Ok(Shown {
        name: node.map(|n| n.name),
        node_id: cap.node_id.clone(),
        version_id: cap.version_id.clone(),
        manifest,
    })
}

pub async fn presign_urls(
    store: &ChunkStore,
    base_url: &str,
    cap: &Capability,
    now: Timestamp,
) -> anyhow::Result<BTreeMap<String, String>> {
    let mut urls = BTreeMap::new();
    for h in &cap.chunk_hashes {
        urls.insert(
            h.clone(),
            store.presign_get(base_url, cap.owner_id, h, now).await?,
        );
    }
    Ok(urls)
}
