//! Bearer device-token auth and the admin door's separate operator credential.
//!
//! `Authorization: Bearer <token>` -> `SHA256(token)` looked up against `devices.token_digest`; a
//! header without the `Bearer ` prefix is used verbatim as the token, as `delete_prefix` did.
//!
//! A token is ADMITTED unless its device is revoked (`revoked_at`, the revoke door) or idled out
//! (`DEVICE_IDLE_DAYS`, device credentials only -- `models::Device` says which those are). Both
//! refusals are the same 401 an unknown token gets: a client cannot tell them apart and has
//! nothing different to do about them (sign in again). `/cable` admits through `admit_token`
//! too, and re-admits its open socket through `readmit`, so no door skips the rule.
//!
//! An admitted request moves `devices.last_seen_at`, at most once per
//! `LAST_SEEN_RESOLUTION_SECONDS`; a refused one never does, so a refused request cannot restart
//! the clock it was refused by (the maker app's `Device.authenticate` makes the same promise).

use subtle::ConstantTimeEq as _;

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::ids::sha256_hex;
use crate::models::{Device, User};
use crate::time::Timestamp;

#[derive(Debug, Clone)]
pub struct Identity {
    pub user: User,
    pub device: Device,
}

pub fn bearer_token(authorization: Option<&str>) -> String {
    let raw = authorization.unwrap_or("");
    raw.strip_prefix("Bearer ")
        .unwrap_or(raw)
        .trim()
        .to_string()
}

pub async fn authenticate(
    db: &Db,
    authorization: Option<&str>,
    now: Timestamp,
    idle_days: Option<i64>,
) -> ApiResult<Identity> {
    admit_token(db, &bearer_token(authorization), now, idle_days).await
}

/// The bare token, as `/cable` carries it in its query string.
pub async fn admit_token(
    db: &Db,
    token: &str,
    now: Timestamp,
    idle_days: Option<i64>,
) -> ApiResult<Identity> {
    if token.is_empty() {
        return Err(ApiError::Unauthorized);
    }
    let mut db = db.clone();
    let Some(device) = Device::find_by_digest(&mut db, &sha256_hex(token.as_bytes())).await? else {
        return Err(ApiError::Unauthorized);
    };
    admissible(&device, now, idle_days)?;
    let Some(user) = User::find(&mut db, device.user_id).await? else {
        return Err(ApiError::Unauthorized);
    };
    stamp(&mut db, &device, now).await?;
    Ok(Identity { user, device })
}

/// An open socket's periodic re-check of the device it was admitted as: refused exactly when a
/// fresh request with the same token would be, and stamped the same way, so a device holding the
/// socket open is in use (and never idles out) for as long as it does.
pub async fn readmit(
    db: &Db,
    device_id: i64,
    now: Timestamp,
    idle_days: Option<i64>,
) -> ApiResult<()> {
    let mut db = db.clone();
    let device = Device::find(&mut db, device_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    admissible(&device, now, idle_days)?;
    stamp(&mut db, &device, now).await?;
    Ok(())
}

fn admissible(device: &Device, now: Timestamp, idle_days: Option<i64>) -> ApiResult<()> {
    if device.revoked_at.is_some() || device.idled_out(now, idle_days) {
        return Err(ApiError::Unauthorized);
    }
    Ok(())
}

async fn stamp(db: &mut Db, device: &Device, now: Timestamp) -> ApiResult<()> {
    if device.seen_is_stale(now) {
        Device::touch_seen(db, device.id, now).await?;
    }
    Ok(())
}

/// The admin door: an unset token refuses the ENDPOINT (503, self-diagnosing), never the boot;
/// a device token presented here is simply not a credential this path reads.
pub fn authorize_admin(configured: Option<&str>, authorization: Option<&str>) -> ApiResult<()> {
    let Some(expected) = configured.filter(|s| !s.trim().is_empty()) else {
        return Err(ApiError::ServiceUnavailable(
            "admin_provisioning_disabled".into(),
        ));
    };
    let provided = bearer_token(authorization);
    if provided.len() == expected.len()
        && bool::from(provided.as_bytes().ct_eq(expected.as_bytes()))
    {
        Ok(())
    } else {
        Err(ApiError::Unauthorized)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bearer_prefix_is_optional_and_whitespace_is_trimmed() {
        assert_eq!(bearer_token(Some("Bearer abc ")), "abc");
        assert_eq!(bearer_token(Some("abc")), "abc");
        assert_eq!(bearer_token(Some("")), "");
        assert_eq!(bearer_token(None), "");
    }

    #[test]
    fn admin_door() {
        assert!(
            matches!(authorize_admin(None, Some("Bearer x")), Err(ApiError::ServiceUnavailable(m)) if m == "admin_provisioning_disabled")
        );
        assert!(matches!(
            authorize_admin(Some("  "), Some("Bearer x")),
            Err(ApiError::ServiceUnavailable(_))
        ));
        assert!(matches!(
            authorize_admin(Some("secret"), Some("Bearer nope")),
            Err(ApiError::Unauthorized)
        ));
        assert!(matches!(
            authorize_admin(Some("secret"), None),
            Err(ApiError::Unauthorized)
        ));
        assert!(authorize_admin(Some("secret"), Some("Bearer secret")).is_ok());
    }
}
