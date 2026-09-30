//! Trash / undelete. A delete is a tombstone whose versions are kept, so restore re-points the
//! node at the version it still carries — no new chunks, no re-upload.

use serde::Serialize;

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::models::{Node, Version};
use crate::time::Timestamp;

use super::nodes::{OP_PUT, apply};

#[derive(Debug, Serialize)]
pub struct TrashItem {
    pub node_id: String,
    pub name: String,
    pub kind: String,
    pub parent_node_id: Option<String>,
    pub deleted_at: Timestamp,
    pub size: Option<i64>,
    pub version_id: Option<String>,
}

/// `GET /v1/trash`: every tombstone, newest-deleted first, sizes batch-loaded.
pub async fn list(db: &Db, user_id: i64) -> ApiResult<Vec<TrashItem>> {
    let mut db = db.clone();
    let nodes = Node::trashed(&mut db, user_id).await?;
    let version_ids: Vec<String> = nodes
        .iter()
        .filter_map(|n| n.current_version_id.clone())
        .collect();
    let sizes = Version::sizes(&mut db, user_id, &version_ids).await?;
    Ok(nodes
        .into_iter()
        .map(|n| TrashItem {
            size: n
                .current_version_id
                .as_ref()
                .and_then(|v| sizes.get(v).copied()),
            node_id: n.node_id,
            name: n.name,
            kind: n.kind,
            parent_node_id: n.parent_node_id,
            deleted_at: n.updated_at,
            version_id: n.current_version_id,
        })
        .collect())
}

pub struct Restored {
    pub node_id: String,
    pub parent_node_id: Option<String>,
    /// `None` when the node was already live: an idempotent success with nothing to append.
    pub seq: Option<i64>,
}

/// `POST /v1/trash/:id/restore`. An orphan (its parent tombstoned or gone) is refused with
/// `parent_deleted` unless `to_root`, which re-parents it at the library root.
pub async fn restore(
    db: &Db,
    user_id: i64,
    node_id: &str,
    to_root: bool,
    now: Timestamp,
) -> ApiResult<Restored> {
    let mut dbh = db.clone();
    let mut node = Node::find(&mut dbh, user_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    if !node.deleted {
        return Ok(Restored {
            node_id: node.node_id,
            parent_node_id: node.parent_node_id,
            seq: None,
        });
    }
    let orphaned = parent_deleted(db, user_id, &node).await?;
    if orphaned && !to_root {
        return Err(ApiError::Conflict("parent_deleted".into()));
    }
    node.deleted = false;
    if orphaned {
        node.parent_node_id = None;
    }
    let version_id = node.current_version_id.clone();
    let seq = apply(db, user_id, &mut node, OP_PUT, version_id.as_deref(), now).await?;
    Ok(Restored {
        node_id: node.node_id,
        parent_node_id: node.parent_node_id,
        seq: Some(seq),
    })
}

async fn parent_deleted(db: &Db, user_id: i64, node: &Node) -> ApiResult<bool> {
    let Some(parent_id) = node
        .parent_node_id
        .as_deref()
        .filter(|p| !p.trim().is_empty())
    else {
        return Ok(false);
    };
    let mut db = db.clone();
    Ok(match Node::find(&mut db, user_id, parent_id).await? {
        None => true,
        Some(parent) => parent.deleted,
    })
}
