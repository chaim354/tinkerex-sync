//! Restore a file to a previous version: a NEW version reusing the old manifest (chunks already
//! exist — refcounts bump through the one touch function), propagated like any other change.

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::ids::new_uuid;
use crate::models::{Node, Version, manifest_hashes, touch_refcounts};
use crate::time::Timestamp;

use super::mutation::UserWrite;
use super::nodes::OP_PUT;

pub struct Restored {
    pub version_id: String,
    pub seq: i64,
}

pub async fn call(
    db: &Db,
    user_id: i64,
    node_id: &str,
    version_id: &str,
    now: Timestamp,
) -> ApiResult<Restored> {
    let mut dbh = db.clone();
    let old = Version::find_for_node(&mut dbh, user_id, version_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let mut node = Node::find(&mut dbh, user_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;

    let mut w = UserWrite::begin(db, user_id).await?;
    let seq = w.seq();
    let hashes = manifest_hashes(w.tx(), user_id, &old.manifest_id).await?;
    if !hashes.is_empty() {
        touch_refcounts(w.tx(), user_id, &hashes, 1, now, false).await?;
    }
    let mut version = Version {
        id: None,
        user_id,
        version_id: new_uuid(),
        node_id: node_id.to_string(),
        manifest_id: old.manifest_id.clone(),
        size: old.size,
        device_id: None,
        parent_version_id: node.current_version_id.clone(),
        pinned: false,
        created_at: now,
    };
    version.insert(w.tx()).await?;
    node.current_version_id = Some(version.version_id.clone());
    node.deleted = false;
    node.updated_seq = seq;
    node.save(w.tx(), now).await?;
    w.append(seq, node_id, OP_PUT, Some(&version.version_id), now)
        .await?;
    w.commit().await?;
    Ok(Restored {
        version_id: version.version_id,
        seq,
    })
}
