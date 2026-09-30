//! Tombstone a node AND its whole present subtree in one transaction, one seq and one `delete`
//! entry per node, all minted under the user lock — so the `/v1/tree` snapshot and a
//! changelog-following device never disagree about whether a deleted folder's children remain.

use std::collections::HashSet;

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::models::Node;
use crate::time::{Clock, Timestamp};

use super::mutation::UserWrite;
use super::nodes::OP_DELETE;

/// Returns the LAST seq minted.
pub async fn call(db: &Db, user_id: i64, node_id: &str, now: Timestamp) -> ApiResult<i64> {
    let mut dbh = db.clone();
    let root = Node::find(&mut dbh, user_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let mut w = UserWrite::begin(db, user_id).await?;
    // Collected UNDER the lock so a concurrent add cannot slip a child in after enumeration.
    let targets = collect(w.tx(), user_id, root).await?;
    // Each node gets its own, later `updated_at`: the trash lists newest-deleted first, and Rails
    // stamped every save with a fresh `Time.current`, so a folder's children (saved after it)
    // list before the folder.
    let mut clock = Clock::new();
    let _ = now;
    for (i, mut n) in targets.into_iter().enumerate() {
        let seq = if i == 0 { w.seq() } else { w.next_seq().await? };
        let at = if i == 0 { clock.first() } else { clock.tick() };
        n.deleted = true;
        n.updated_seq = seq;
        n.save(w.tx(), at).await?;
        w.append(seq, &n.node_id, OP_DELETE, None, at).await?;
    }
    w.commit().await
}

/// The root plus every present descendant, BFS over `parent_node_id`, bounded by a `seen` set.
async fn collect<E: crate::db::Exec>(e: &mut E, user_id: i64, root: Node) -> ApiResult<Vec<Node>> {
    let mut seen: HashSet<String> = HashSet::from([root.node_id.clone()]);
    let mut frontier = vec![root.node_id.clone()];
    let mut targets = vec![root];
    while !frontier.is_empty() {
        let children = Node::present_children(e, user_id, &frontier, &seen).await?;
        if children.is_empty() {
            break;
        }
        frontier = children.iter().map(|c| c.node_id.clone()).collect();
        for c in &children {
            seen.insert(c.node_id.clone());
        }
        targets.extend(children);
    }
    Ok(targets)
}
