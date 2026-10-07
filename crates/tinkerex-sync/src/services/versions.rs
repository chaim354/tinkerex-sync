//! `GET /v1/nodes/:id/versions`: the 200 most recent versions of one node, newest first.

use serde::Serialize;

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::models::{Node, Version};
use crate::time::Timestamp;

pub const LIMIT: i64 = 200;

#[derive(Debug, Serialize)]
pub struct VersionOut {
    pub version_id: String,
    pub manifest_id: String,
    pub size: i64,
    pub parent_version_id: Option<String>,
    pub created_at: Timestamp,
}

pub async fn list(db: &Db, user_id: i64, node_id: &str) -> ApiResult<Vec<VersionOut>> {
    let mut db = db.clone();
    let node = Node::find(&mut db, user_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(
        Version::list_for_node(&mut db, user_id, &node.node_id, LIMIT)
            .await?
            .into_iter()
            .map(|v| VersionOut {
                version_id: v.version_id,
                manifest_id: v.manifest_id,
                size: v.size,
                parent_version_id: v.parent_version_id,
                created_at: v.created_at,
            })
            .collect(),
    )
}
