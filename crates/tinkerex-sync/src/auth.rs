//! Bearer device-token auth and the admin door's separate operator credential.
//!
//! `Authorization: Bearer <token>` -> `SHA256(token)` looked up against `devices.token_digest`; a
//! header without the `Bearer ` prefix is used verbatim as the token, as `delete_prefix` did. Every
//! authenticated request stamps `devices.last_seen_at`. There is no distinct expired/revoked status:
//! a device's access is binary.

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
) -> ApiResult<Identity> {
    let token = bearer_token(authorization);
    if token.is_empty() {
        return Err(ApiError::Unauthorized);
    }
    let mut db = db.clone();
    let Some(device) = Device::find_by_digest(&mut db, &sha256_hex(token.as_bytes())).await? else {
        return Err(ApiError::Unauthorized);
    };
    let Some(user) = User::find(&mut db, device.user_id).await? else {
        return Err(ApiError::Unauthorized);
    };
    Device::touch_seen(&mut db, device.id, now).await?;
    Ok(Identity { user, device })
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
