//! The pull delta: changelog entries with `seq > cursor`, each carrying the node's current state
//! and, for content commits, the version and its manifest. Batch-loaded: a page of N entries costs
//! a bounded number of queries.

use serde::Serialize;

use crate::db::Db;
use crate::error::ApiResult;
use crate::models::{ChangelogEntry, ChunkRef, Node, User, Version, load_manifests};

use super::nodes::OP_PUT;
use super::tree::encode_target;

#[derive(Debug, Serialize)]
pub struct ChangeNode {
    pub node_id: String,
    pub parent_node_id: Option<String>,
    pub name: String,
    pub kind: String,
    pub deleted: bool,
    pub mode: Option<i64>,
    pub mtime: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symlink_target: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ChangeVersion {
    pub version_id: String,
    pub manifest_id: String,
    pub size: i64,
}

#[derive(Debug, Serialize)]
pub struct Change {
    pub seq: i64,
    pub op: String,
    pub node_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub node: Option<ChangeNode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<ChangeVersion>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manifest: Option<Vec<ChunkRef>>,
}

#[derive(Debug, Serialize)]
pub struct ChangesPage {
    pub changes: Vec<Change>,
    pub head_seq: i64,
    /// The oldest entry still retained; `head_seq + 1` on an empty table, deliberately not 0, so
    /// a behind cursor detects a pruned gap instead of fast-forwarding past it.
    pub oldest_seq: i64,
}

pub async fn call(db: &Db, user_id: i64, since: i64, limit: i64) -> ApiResult<ChangesPage> {
    let mut db = db.clone();
    let entries = ChangelogEntry::since(&mut db, user_id, since, limit).await?;
    let node_ids: Vec<String> = entries.iter().map(|e| e.node_id.clone()).collect();
    let nodes = Node::find_many(&mut db, user_id, &node_ids).await?;
    let version_ids: Vec<String> = entries
        .iter()
        .filter(|e| e.op == OP_PUT)
        .filter_map(|e| e.version_id.clone())
        .filter(|v| !v.is_empty())
        .collect();
    let versions = Version::find_many(&mut db, user_id, &version_ids).await?;
    let manifest_ids: Vec<String> = versions.values().map(|v| v.manifest_id.clone()).collect();
    let manifests = load_manifests(&mut db, user_id, &manifest_ids).await?;
    let head_seq = User::head_seq(&mut db, user_id).await?;
    let oldest_seq = ChangelogEntry::min_seq(&mut db, user_id)
        .await?
        .unwrap_or(head_seq + 1);

    let changes = entries
        .into_iter()
        .map(|e| {
            let node = nodes.get(&e.node_id).map(|n| ChangeNode {
                node_id: n.node_id.clone(),
                parent_node_id: n.parent_node_id.clone(),
                name: n.name.clone(),
                kind: n.kind.clone(),
                deleted: n.deleted,
                mode: n.mode,
                mtime: n.mtime,
                symlink_target: if n.is_symlink() {
                    n.symlink_target.as_deref().map(encode_target)
                } else {
                    None
                },
            });
            let (version, manifest) = match (
                e.op.as_str(),
                e.version_id.as_deref().filter(|v| !v.is_empty()),
            ) {
                (OP_PUT, Some(vid)) => match versions.get(vid) {
                    Some(v) => (
                        Some(ChangeVersion {
                            version_id: v.version_id.clone(),
                            manifest_id: v.manifest_id.clone(),
                            size: v.size,
                        }),
                        Some(manifests.get(&v.manifest_id).cloned().unwrap_or_default()),
                    ),
                    None => (None, None),
                },
                _ => (None, None),
            };
            Change {
                seq: e.seq,
                op: e.op,
                node_id: e.node_id,
                node,
                version,
                manifest,
            }
        })
        .collect();
    Ok(ChangesPage {
        changes,
        head_seq,
        oldest_seq,
    })
}
