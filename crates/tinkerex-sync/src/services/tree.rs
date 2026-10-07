//! The full-tree snapshot a device pairs with, paginated by the nodes table's own id: a bounded
//! number of queries per page (nodes, versions, manifests), never one per row.

use serde::Serialize;

use crate::db::Db;
use crate::error::ApiResult;
use crate::models::{ChunkRef, Node, User, Version, load_manifests};

#[derive(Debug, Serialize)]
pub struct TreeNode {
    pub node_id: String,
    pub parent_node_id: Option<String>,
    pub name: String,
    pub kind: String,
    pub mode: Option<i64>,
    pub mtime: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manifest: Option<Vec<ChunkRef>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symlink_target: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct TreePage {
    pub nodes: Vec<TreeNode>,
    pub head_seq: i64,
    pub next_after_id: Option<i64>,
}

pub fn encode_target(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

pub async fn call(db: &Db, user_id: i64, after_id: i64, limit: i64) -> ApiResult<TreePage> {
    let mut db = db.clone();
    let nodes = Node::present_page(&mut db, user_id, after_id, limit).await?;
    let version_ids: Vec<String> = nodes
        .iter()
        .filter(|n| n.is_file())
        .filter_map(|n| n.current_version_id.clone())
        .collect();
    let versions = Version::find_many(&mut db, user_id, &version_ids).await?;
    let manifest_ids: Vec<String> = versions.values().map(|v| v.manifest_id.clone()).collect();
    let manifests = load_manifests(&mut db, user_id, &manifest_ids).await?;
    let head_seq = User::head_seq(&mut db, user_id).await?;
    let next_after_id = nodes.last().and_then(|n| n.id);
    let out = nodes
        .into_iter()
        .map(|n| {
            let mut t = TreeNode {
                node_id: n.node_id.clone(),
                parent_node_id: n.parent_node_id.clone(),
                name: n.name.clone(),
                kind: n.kind.clone(),
                mode: n.mode,
                mtime: n.mtime,
                version_id: None,
                size: None,
                manifest: None,
                symlink_target: None,
            };
            if n.is_file() {
                if let Some(v) = n
                    .current_version_id
                    .as_ref()
                    .and_then(|id| versions.get(id))
                {
                    t.version_id = Some(v.version_id.clone());
                    t.size = Some(v.size);
                    t.manifest = Some(manifests.get(&v.manifest_id).cloned().unwrap_or_default());
                }
            } else if let (true, Some(target)) = (n.is_symlink(), &n.symlink_target) {
                t.symlink_target = Some(encode_target(target));
            }
            t
        })
        .collect();
    Ok(TreePage {
        nodes: out,
        head_seq,
        next_after_id,
    })
}
