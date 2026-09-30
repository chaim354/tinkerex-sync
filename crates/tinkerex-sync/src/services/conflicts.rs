//! Resolving a file divergence: `keep(version_id)` makes one side current (the other stays in
//! history); `split` keeps both, with every divergent incoming version becoming a new sibling
//! file that reuses its manifest — zero new bytes.

use std::collections::HashSet;

use serde::Serialize;

use crate::db::{Db, Exec};
use crate::error::{ApiError, ApiResult};
use crate::ids::new_uuid;
use crate::models::{Conflict, Device, KIND_FILE, Node, Version, manifest_hashes, touch_refcounts};
use crate::time::Timestamp;

use super::mutation::UserWrite;
use super::nodes::OP_PUT;

#[derive(Debug, Serialize)]
pub struct VersionDetail {
    pub version_id: String,
    pub size: i64,
    pub created_at: Timestamp,
    pub device_name: String,
}

#[derive(Debug, Serialize)]
pub struct ConflictOut {
    pub node_id: String,
    pub name: Option<String>,
    pub current: Option<VersionDetail>,
    pub incoming: Option<VersionDetail>,
}

async fn device_name<E: Exec>(
    e: &mut E,
    user_id: i64,
    device_id: Option<i64>,
) -> ApiResult<String> {
    Ok(Device::name_of(e, user_id, device_id)
        .await?
        .unwrap_or_else(|| "another device".to_string()))
}

async fn version_detail<E: Exec>(
    e: &mut E,
    user_id: i64,
    version_id: &str,
) -> ApiResult<Option<VersionDetail>> {
    let Some(v) = Version::find(e, user_id, version_id).await? else {
        return Ok(None);
    };
    let device_name = device_name(e, user_id, v.device_id).await?;
    Ok(Some(VersionDetail {
        version_id: v.version_id,
        size: v.size,
        created_at: v.created_at,
        device_name,
    }))
}

/// `GET /v1/conflicts`: one row per `(node, incoming version)`, both sides' details.
pub async fn list(db: &Db, user_id: i64) -> ApiResult<Vec<ConflictOut>> {
    let mut db = db.clone();
    let mut out = Vec::new();
    for c in Conflict::unresolved_all(&mut db, user_id).await? {
        let node = Node::find(&mut db, user_id, &c.node_id).await?;
        out.push(ConflictOut {
            node_id: c.node_id.clone(),
            name: node.map(|n| n.name),
            current: version_detail(&mut db, user_id, &c.current_version_id).await?,
            incoming: version_detail(&mut db, user_id, &c.incoming_version_id).await?,
        });
    }
    Ok(out)
}

/// Keep one side as current and resolve EVERY open conflict row for the node.
pub async fn keep(
    db: &Db,
    user_id: i64,
    node_id: &str,
    version_id: &str,
    now: Timestamp,
) -> ApiResult<i64> {
    let mut dbh = db.clone();
    let conflicts = Conflict::unresolved_for_node(&mut dbh, user_id, node_id).await?;
    if conflicts.is_empty() {
        return Err(ApiError::NotFound);
    }
    let valid: HashSet<&str> = conflicts
        .iter()
        .flat_map(|c| {
            [
                c.current_version_id.as_str(),
                c.incoming_version_id.as_str(),
            ]
        })
        .collect();
    if !valid.contains(version_id) {
        return Err(ApiError::Unprocessable(
            "version is not part of this conflict".into(),
        ));
    }
    let mut w = UserWrite::begin(db, user_id).await?;
    let seq = w.seq();
    let mut node = Node::find(w.tx(), user_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    node.current_version_id = Some(version_id.to_string());
    node.updated_seq = seq;
    node.save(w.tx(), now).await?;
    w.append(seq, node_id, OP_PUT, Some(version_id), now)
        .await?;
    Conflict::resolve_node(w.tx(), user_id, node_id, now).await?;
    w.commit().await
}

pub struct Split {
    pub first_node_id: String,
    pub node_ids: Vec<String>,
    pub seq: i64,
}

/// Keep all: the node stays at its current version; EACH divergent incoming version becomes a
/// new sibling file reusing its manifest (refcount +1). Each sibling gets its own seq.
pub async fn split(db: &Db, user_id: i64, node_id: &str, now: Timestamp) -> ApiResult<Split> {
    let mut dbh = db.clone();
    let conflicts = Conflict::unresolved_for_node(&mut dbh, user_id, node_id).await?;
    if conflicts.is_empty() {
        return Err(ApiError::NotFound);
    }
    let mut w = UserWrite::begin(db, user_id).await?;
    let node = Node::find(w.tx(), user_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let mut seen: HashSet<String> = HashSet::new();
    let mut new_node_ids: Vec<String> = Vec::new();
    for c in &conflicts {
        if !seen.insert(c.incoming_version_id.clone()) {
            continue;
        }
        let incoming = Version::find(w.tx(), user_id, &c.incoming_version_id)
            .await?
            .ok_or(ApiError::NotFound)?;
        let hashes = manifest_hashes(w.tx(), user_id, &incoming.manifest_id).await?;
        if !hashes.is_empty() {
            touch_refcounts(w.tx(), user_id, &hashes, 1, now, false).await?;
        }
        let this_seq = if new_node_ids.is_empty() {
            w.seq()
        } else {
            w.next_seq().await?
        };
        let new_node_id = new_uuid();
        let name = conflicted_name(w.tx(), user_id, &node.name, &incoming).await?;
        let mut version = Version {
            id: None,
            user_id,
            version_id: new_uuid(),
            node_id: new_node_id.clone(),
            manifest_id: incoming.manifest_id.clone(),
            size: incoming.size,
            device_id: incoming.device_id,
            parent_version_id: None,
            pinned: false,
            created_at: now,
        };
        let mut copy = Node::new(user_id, &new_node_id, now);
        copy.parent_node_id = node.parent_node_id.clone();
        copy.name = name;
        copy.kind = KIND_FILE.to_string();
        copy.deleted = false;
        copy.save(w.tx(), now).await?;
        version.insert(w.tx()).await?;
        copy.current_version_id = Some(version.version_id.clone());
        copy.updated_seq = this_seq;
        copy.save(w.tx(), now).await?;
        w.append(
            this_seq,
            &new_node_id,
            OP_PUT,
            Some(&version.version_id),
            now,
        )
        .await?;
        new_node_ids.push(new_node_id);
    }
    Conflict::resolve_node(w.tx(), user_id, node_id, now).await?;
    let seq = w.commit().await?;
    Ok(Split {
        first_node_id: new_node_ids.first().cloned().unwrap_or_default(),
        node_ids: new_node_ids,
        seq,
    })
}

/// `"<base> (conflict from <device> <YYYY-MM-DD HHMM>)<ext>"`, stamped with the INCOMING
/// version's own `created_at`.
async fn conflicted_name<E: Exec>(
    e: &mut E,
    user_id: i64,
    name: &str,
    version: &Version,
) -> ApiResult<String> {
    let who = device_name(e, user_id, version.device_id).await?;
    let stamp = version.created_at.to_conflict_stamp();
    let (base, ext) = split_extname(name);
    Ok(format!("{base} (conflict from {who} {stamp}){ext}"))
}

/// Ruby's `File.extname`: the last dot-suffix, unless the dot is the name's first character.
pub fn split_extname(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extname_like_ruby() {
        assert_eq!(split_extname("triple.txt"), ("triple", ".txt"));
        assert_eq!(split_extname("archive.tar.gz"), ("archive.tar", ".gz"));
        assert_eq!(split_extname("README"), ("README", ""));
        assert_eq!(split_extname(".bashrc"), (".bashrc", ""));
    }
}
