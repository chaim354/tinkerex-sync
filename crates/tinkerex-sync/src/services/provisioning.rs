//! Minting users and devices: the operator's `device issue` and `POST /v1/admin/libraries` for a
//! brand-new library mint LIBRARY credentials; `POST /v1/devices` mints a DEVICE credential that
//! records its issuer (`models::Device` has the difference). The plaintext token is returned
//! exactly once; only its SHA-256 digest is stored.

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::ids::{new_token, sha256_hex};
use crate::models::{Device, User};
use crate::services::mutation::UserLock;
use crate::time::Timestamp;

pub struct IssuedDevice {
    pub user_id: i64,
    pub device_id: i64,
    pub device_token: String,
}

/// Register a LIBRARY credential for an existing user (`Device.register!`): the out-of-band doors.
pub async fn register_device(
    db: &Db,
    user_id: i64,
    name: &str,
    now: Timestamp,
) -> ApiResult<IssuedDevice> {
    let mut db = db.clone();
    let token = new_token();
    let device = Device::create(
        &mut db,
        user_id,
        name,
        &sha256_hex(token.as_bytes()),
        None,
        now,
    )
    .await?;
    Ok(IssuedDevice {
        user_id,
        device_id: device.id,
        device_token: token,
    })
}

/// `POST /v1/devices`: a device credential minted by `issuer`, which must still be unrevoked once
/// the user lock is held -- a revocation that committed after this request authenticated must not
/// leave a live child behind it.
pub async fn register_sibling(
    db: &Db,
    issuer: &Device,
    name: &str,
    now: Timestamp,
) -> ApiResult<IssuedDevice> {
    let mut lock = UserLock::begin(db, issuer.user_id).await?;
    let current = Device::find(lock.tx(), issuer.id).await?;
    if current.is_none_or(|d| d.revoked_at.is_some()) {
        return Err(ApiError::Unauthorized);
    }
    let token = new_token();
    let device = Device::create(
        lock.tx(),
        issuer.user_id,
        name,
        &sha256_hex(token.as_bytes()),
        Some(issuer.id),
        now,
    )
    .await?;
    lock.commit().await?;
    Ok(IssuedDevice {
        user_id: issuer.user_id,
        device_id: device.id,
        device_token: token,
    })
}

/// The operator's `device issue` (the Rails host's `sync:device:issue`): creates the user if absent.
pub async fn issue_for_email(
    db: &Db,
    email: &str,
    name: &str,
    now: Timestamp,
) -> ApiResult<IssuedDevice> {
    let mut dbh = db.clone();
    let user = match User::find_by_email(&mut dbh, email).await? {
        Some(u) => u,
        None => User::create(&mut dbh, email, now).await?,
    };
    register_device(db, user.id, name, now).await
}

/// `POST /v1/admin/libraries`: a brand-new user plus its first device. A repeat call for the same
/// email refuses (409 `email_taken`) — it never mints a second credential onto an existing library.
pub async fn provision_library(
    db: &Db,
    email: &str,
    name: &str,
    now: Timestamp,
) -> ApiResult<IssuedDevice> {
    let mut dbh = db.clone();
    if User::find_by_email(&mut dbh, email).await?.is_some() {
        return Err(ApiError::Conflict("email_taken".into()));
    }
    let user = User::create(&mut dbh, email, now).await?;
    register_device(db, user.id, name, now).await
}
