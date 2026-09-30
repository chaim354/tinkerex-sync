//! The metadata mutation surface: mkdir, symlink, move — each one `Sync::Mutation.apply` with its
//! two guards (a cycle, a kind change) evaluated before any write.

use std::collections::HashSet;

use base64::Engine as _;

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::models::{KIND_DIR, KIND_SYMLINK, Node};
use crate::time::Timestamp;

use super::mutation::UserWrite;

pub const OP_MKDIR: &str = "mkdir";
pub const OP_SYMLINK: &str = "symlink";
pub const OP_MOVE: &str = "move";
pub const OP_DELETE: &str = "delete";
pub const OP_PUT: &str = "put";
pub const OP_CONFLICT: &str = "conflict";

pub struct MkdirParams {
    pub node_id: String,
    pub parent_node_id: Option<String>,
    /// Required, but only checked where Rails checked it: after the kind and cycle guards.
    pub name: Option<String>,
    pub mode: Option<i64>,
    pub mtime: Option<i64>,
}

pub struct SymlinkParams {
    pub node_id: String,
    pub parent_node_id: Option<String>,
    /// Required, but only checked after the kind guard and the target decode, as Rails did.
    pub name: Option<String>,
    /// The base64 text as sent; blank means a NULL target.
    pub symlink_target: Option<String>,
    pub mode: Option<i64>,
    pub mtime: Option<i64>,
}

pub struct MoveParams {
    pub node_id: String,
    /// `Some(parent)` when the key was sent (an explicit null moves to the root), `None` when omitted.
    pub new_parent: Option<Option<String>>,
    pub new_name: Option<String>,
}

/// A move/re-parent is a cycle iff the target parent is the node itself, or the node appears in
/// the target parent's ancestor chain. Walked up with a `seen` guard so an already-corrupt tree
/// cannot spin it.
pub async fn would_create_cycle(
    db: &Db,
    user_id: i64,
    node_id: &str,
    new_parent: Option<&str>,
) -> ApiResult<bool> {
    let Some(mut current) = new_parent
        .filter(|p| !p.trim().is_empty())
        .map(str::to_string)
    else {
        return Ok(false);
    };
    if current == node_id {
        return Ok(true);
    }
    let mut db = db.clone();
    let mut seen = HashSet::new();
    loop {
        if current == node_id {
            return Ok(true);
        }
        if !seen.insert(current.clone()) {
            return Ok(false);
        }
        match Node::parent_of(&mut db, user_id, &current).await? {
            Some(Some(parent)) if !parent.is_empty() => current = parent,
            _ => return Ok(false),
        }
    }
}

fn missing_param(name: &str) -> ApiError {
    ApiError::BadRequest(format!(
        "param is missing or the value is empty or invalid: {name}"
    ))
}

fn cycle_error() -> ApiError {
    ApiError::Unprocessable("move would create a cycle".into())
}

/// A mutation that would change an EXISTING node's kind would orphan its versions/children.
fn reject_kind_change(node: &Node, new_kind: &str) -> ApiResult<()> {
    if node.persisted() && node.kind != new_kind {
        return Err(ApiError::Conflict(format!(
            "node {} already exists as a {}, cannot become a {}",
            node.node_id, node.kind, new_kind
        )));
    }
    Ok(())
}

/// `POST /v1/nodes`: create a directory, or re-parent/rename an existing one in place.
pub async fn mkdir(db: &Db, user_id: i64, p: MkdirParams, now: Timestamp) -> ApiResult<i64> {
    let mut dbh = db.clone();
    let mut node = Node::find(&mut dbh, user_id, &p.node_id)
        .await?
        .unwrap_or_else(|| Node::new(user_id, &p.node_id, now));
    reject_kind_change(&node, KIND_DIR)?;
    if would_create_cycle(db, user_id, &p.node_id, p.parent_node_id.as_deref()).await? {
        return Err(cycle_error());
    }
    let name = p
        .name
        .filter(|n| !n.trim().is_empty())
        .ok_or_else(|| missing_param("name"))?;
    node.parent_node_id = p.parent_node_id;
    node.name = name;
    node.kind = KIND_DIR.to_string();
    node.deleted = false;
    node.mode = Some(p.mode.or(node.mode).unwrap_or(0o755));
    node.mtime = p.mtime.or(node.mtime);
    apply(db, user_id, &mut node, OP_MKDIR, None, now).await
}

/// `POST /v1/nodes/symlink`: create or update a symlink node — metadata only, no version.
pub async fn symlink(db: &Db, user_id: i64, p: SymlinkParams, now: Timestamp) -> ApiResult<i64> {
    let mut dbh = db.clone();
    let mut node = Node::find(&mut dbh, user_id, &p.node_id)
        .await?
        .unwrap_or_else(|| Node::new(user_id, &p.node_id, now));
    reject_kind_change(&node, KIND_SYMLINK)?;
    let target = match p
        .symlink_target
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        Some(text) => Some(
            base64::engine::general_purpose::STANDARD
                .decode(text)
                .map_err(|e| ApiError::Unprocessable(format!("invalid base64: {e}")))?,
        ),
        None => None,
    };
    let name = p
        .name
        .filter(|n| !n.trim().is_empty())
        .ok_or_else(|| missing_param("name"))?;
    node.parent_node_id = p.parent_node_id;
    node.name = name;
    node.kind = KIND_SYMLINK.to_string();
    node.deleted = false;
    node.symlink_target = target;
    node.mode = Some(p.mode.or(node.mode).unwrap_or(0o777));
    node.mtime = p.mtime.or(node.mtime);
    apply(db, user_id, &mut node, OP_SYMLINK, None, now).await
}

/// `POST /v1/nodes/:id/move`.
pub async fn move_node(db: &Db, user_id: i64, p: MoveParams, now: Timestamp) -> ApiResult<i64> {
    let mut dbh = db.clone();
    let mut node = Node::find(&mut dbh, user_id, &p.node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    if let Some(new_parent) = &p.new_parent {
        if would_create_cycle(db, user_id, &p.node_id, new_parent.as_deref()).await? {
            return Err(cycle_error());
        }
        node.parent_node_id = new_parent.clone();
    }
    if let Some(name) = p.new_name.as_deref().filter(|n| !n.trim().is_empty()) {
        node.name = name.to_string();
    }
    apply(db, user_id, &mut node, OP_MOVE, None, now).await
}

/// `Sync::Mutation.apply`: seq first, then the node write, then exactly one changelog entry.
pub async fn apply(
    db: &Db,
    user_id: i64,
    node: &mut Node,
    op: &str,
    version_id: Option<&str>,
    now: Timestamp,
) -> ApiResult<i64> {
    let mut w = UserWrite::begin(db, user_id).await?;
    let seq = w.seq();
    node.updated_seq = seq;
    node.save(w.tx(), now).await?;
    w.append(seq, &node.node_id, op, version_id, now).await?;
    w.commit().await
}
