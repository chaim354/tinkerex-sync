//! Best-effort advisory edit locks. `acquire` grants/refreshes unless another device holds an
//! unexpired one (a live lock is never stolen); the TTL means a vanished holder cannot wedge a
//! file. Lock and unlock both 404 for a node that is not LIVE — the same 404 as an unknown id, so
//! this endpoint is never an oracle for which ids were ever real.

use serde::Serialize;

use crate::db::{Db, Exec};
use crate::error::{ApiError, ApiResult};
use crate::models::{Device, FileLock, Node};
use crate::time::Timestamp;

pub const TTL_SECONDS: i64 = 300;

#[derive(Debug, Serialize)]
pub struct LockStatus {
    pub node_id: String,
    pub held: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub by_me: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<Timestamp>,
}

async fn status<E: Exec>(
    e: &mut E,
    user_id: i64,
    lock: &FileLock,
    device_id: Option<i64>,
) -> ApiResult<LockStatus> {
    let name = Device::name_of(e, user_id, Some(lock.device_id))
        .await?
        .unwrap_or_else(|| "another device".to_string());
    Ok(LockStatus {
        node_id: lock.node_id.clone(),
        held: true,
        by_me: Some(device_id == Some(lock.device_id)),
        device_name: Some(name),
        expires_at: Some(lock.expires_at),
    })
}

pub async fn acquire(
    db: &Db,
    user_id: i64,
    node_id: &str,
    device_id: i64,
    now: Timestamp,
) -> ApiResult<LockStatus> {
    let mut db = db.clone();
    Node::find_present(&mut db, user_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let existing = FileLock::find(&mut db, user_id, node_id).await?;
    let held_by_other = existing
        .as_ref()
        .map(|l| l.expires_at > now && l.device_id != device_id)
        .unwrap_or(false);
    if !held_by_other {
        let expires_at = now.plus_seconds(TTL_SECONDS);
        let write = match &existing {
            Some(l) => FileLock::update(&mut db, l.id, device_id, expires_at, now).await,
            None => FileLock::insert(&mut db, user_id, node_id, device_id, expires_at, now).await,
        };
        if let Err(e) = write {
            // Two devices raced to CREATE the row; the unique index rejected the loser. Benign:
            // re-read and report the winner's status.
            let is_unique = matches!(&e, sqlx::Error::Database(d) if d.is_unique_violation());
            if !is_unique {
                return Err(e.into());
            }
            return match FileLock::find(&mut db, user_id, node_id).await? {
                Some(l) => status(&mut db, user_id, &l, Some(device_id)).await,
                None => Ok(LockStatus {
                    node_id: node_id.to_string(),
                    held: false,
                    by_me: None,
                    device_name: None,
                    expires_at: None,
                }),
            };
        }
    }
    let lock = FileLock::find(&mut db, user_id, node_id)
        .await?
        .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("lock vanished after write")))?;
    status(&mut db, user_id, &lock, Some(device_id)).await
}

#[derive(Debug, Serialize)]
pub struct Released {
    pub released: bool,
}

pub async fn release(
    db: &Db,
    user_id: i64,
    node_id: &str,
    device_id: i64,
    now: Timestamp,
) -> ApiResult<Released> {
    let _ = now;
    let mut db = db.clone();
    Node::find_present(&mut db, user_id, node_id)
        .await?
        .ok_or(ApiError::NotFound)?;
    let lock = FileLock::find(&mut db, user_id, node_id).await?;
    let released = lock
        .as_ref()
        .map(|l| l.device_id == device_id)
        .unwrap_or(false);
    if let (true, Some(l)) = (released, lock) {
        FileLock::delete(&mut db, l.id).await?;
    }
    Ok(Released { released })
}

pub async fn active(
    db: &Db,
    user_id: i64,
    device_id: Option<i64>,
    now: Timestamp,
) -> ApiResult<Vec<LockStatus>> {
    let mut db = db.clone();
    let mut out = Vec::new();
    for l in FileLock::active(&mut db, user_id, now).await? {
        out.push(status(&mut db, user_id, &l, device_id).await?);
    }
    Ok(out)
}
