//! Revoking devices (tinkerex#473): `DELETE /v1/devices/:id`, and the operator's `device revoke`.
//!
//! WHO MAY REVOKE WHAT, through the door, in one library (`models::Device` defines the kinds):
//!   - a library credential may revoke any DEVICE credential -- this is how the maker app, holding
//!     the user's bootstrap token, signs a desktop out of sync (`devices.sync_device_id` there);
//!   - a device credential may revoke itself, and the devices it minted (transitively) -- a
//!     device can sign itself out, and take back what it handed out, but it cannot reach a sibling
//!     or the device that minted it. The maker app keeps the same line on its own side: a stolen
//!     token must not be able to keep itself alive by signing the real one out;
//!   - nobody revokes a library credential here, itself included: nothing can re-mint one through
//!     the API (the admin door refuses an existing email), so losing the maker app's token would
//!     strand that user's library until an operator issued another by hand.
//!
//! The operator's `device revoke` (`revoke_as_operator`) is the one door with no such rule.
//!
//! A revocation CASCADES to every device the target minted, transitively, so a sibling minted in
//! advance by a stolen token dies with it. It is idempotent: the rows are kept (`revoked_at`, set
//! once), so a repeat finds the same subtree already revoked and answers the same way.
//!
//! Minting (`provisioning::register_sibling`) and revoking both run under the user lock, so a mint
//! racing a revocation either lands first and is caught by the cascade, or finds its issuer
//! revoked.
//!
//! What a revocation does NOT reach: a request already past authentication finishes (bounded by
//! the 120 s request timeout); presigned chunk URLs it was handed stay valid until their own `exp`;
//! a lock it holds lapses with its 300 s TTL; share links are the library's, not the device's.

use std::collections::{HashMap, HashSet};

use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use crate::models::Device;
use crate::services::mutation::UserLock;
use crate::time::Timestamp;

/// Why a target in the caller's own library is out of the caller's reach. Both are 403s: the
/// target's existence is no secret to a credential of the same library, and a 404 here would let
/// the maker app read "already gone" for a device that is still syncing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The target is a library credential.
    LibraryCredential,
    /// A device credential reaching outside its own subtree.
    NotTheIssuer,
}

impl From<Refusal> for ApiError {
    fn from(r: Refusal) -> Self {
        ApiError::Forbidden(
            match r {
                Refusal::LibraryCredential => "library_credential",
                Refusal::NotTheIssuer => "forbidden",
            }
            .into(),
        )
    }
}

/// The door's rule, over one library's lineage (`issuer` maps each device to its minter).
pub fn may_revoke(
    caller: i64,
    target: i64,
    issuer: &HashMap<i64, Option<i64>>,
) -> Result<(), Refusal> {
    let issuer_of = |id: i64| issuer.get(&id).copied().flatten();
    if issuer_of(target).is_none() {
        return Err(Refusal::LibraryCredential);
    }
    if issuer_of(caller).is_none() || caller == target {
        return Ok(());
    }
    // Walk up from the target; the lineage is a tree (an issuer always predates what it mints),
    // and the visited set makes a corrupted row a refusal rather than a hang.
    let mut seen = HashSet::new();
    let mut cursor = issuer_of(target);
    while let Some(id) = cursor {
        if id == caller {
            return Ok(());
        }
        if !seen.insert(id) {
            break;
        }
        cursor = issuer_of(id);
    }
    Err(Refusal::NotTheIssuer)
}

/// `root` and everything it minted, transitively.
pub fn subtree(root: i64, issuer: &HashMap<i64, Option<i64>>) -> Vec<i64> {
    let mut out = vec![root];
    let mut i = 0;
    while i < out.len() {
        let parent = out[i];
        let mut children: Vec<i64> = issuer
            .iter()
            .filter(|(id, by)| **by == Some(parent) && !out.contains(id))
            .map(|(id, _)| *id)
            .collect();
        children.sort_unstable();
        out.extend(children);
        i += 1;
    }
    out
}

fn lineage(devices: &[Device]) -> HashMap<i64, Option<i64>> {
    devices.iter().map(|d| (d.id, d.issuer_device_id)).collect()
}

/// The door. Returns every id in the revoked subtree (for the cable hub to cut their sockets).
/// An id that is not a device of the caller's library -- unknown, or another library's -- is the
/// plain 404 every other foreign id gets.
pub async fn revoke(
    db: &Db,
    caller: &Device,
    target_id: i64,
    now: Timestamp,
) -> ApiResult<Vec<i64>> {
    let mut lock = UserLock::begin(db, caller.user_id).await?;
    let devices = Device::list_for_user(lock.tx(), caller.user_id).await?;
    let issuer = lineage(&devices);
    if !issuer.contains_key(&target_id) {
        return Err(ApiError::NotFound);
    }
    may_revoke(caller.id, target_id, &issuer)?;
    let ids = subtree(target_id, &issuer);
    Device::mark_revoked(lock.tx(), caller.user_id, &ids, now).await?;
    lock.commit().await?;
    Ok(ids)
}

/// The operator's `device revoke`: any device, library credentials included, with the same
/// cascade. Returns the revoked subtree, or `None` for an id no device has.
pub async fn revoke_as_operator(
    db: &Db,
    device_id: i64,
    now: Timestamp,
) -> ApiResult<Option<(Device, Vec<i64>)>> {
    let mut dbh = db.clone();
    let Some(target) = Device::find(&mut dbh, device_id).await? else {
        return Ok(None);
    };
    let mut lock = UserLock::begin(db, target.user_id).await?;
    let devices = Device::list_for_user(lock.tx(), target.user_id).await?;
    let ids = subtree(target.id, &lineage(&devices));
    Device::mark_revoked(lock.tx(), target.user_id, &ids, now).await?;
    lock.commit().await?;
    Ok(Some((target, ids)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 1 and 2 are library credentials; 3 and 4 were minted by 1; 5 by 3; 6 by 5.
    fn library() -> HashMap<i64, Option<i64>> {
        HashMap::from([
            (1, None),
            (2, None),
            (3, Some(1)),
            (4, Some(1)),
            (5, Some(3)),
            (6, Some(5)),
        ])
    }

    #[test]
    fn a_library_credential_reaches_every_device_credential_and_no_library_credential() {
        let l = library();
        for target in [3, 4, 5, 6] {
            assert_eq!(may_revoke(1, target, &l), Ok(()), "1 -> {target}");
            assert_eq!(
                may_revoke(2, target, &l),
                Ok(()),
                "2 -> {target}: any library credential, not only the issuer"
            );
        }
        for target in [1, 2] {
            assert_eq!(
                may_revoke(1, target, &l),
                Err(Refusal::LibraryCredential),
                "1 -> {target}"
            );
        }
    }

    #[test]
    fn a_device_credential_reaches_itself_and_its_own_subtree_only() {
        let l = library();
        assert_eq!(may_revoke(3, 3, &l), Ok(()), "itself");
        assert_eq!(may_revoke(3, 5, &l), Ok(()), "its child");
        assert_eq!(may_revoke(3, 6, &l), Ok(()), "its grandchild");
        assert_eq!(
            may_revoke(3, 4, &l),
            Err(Refusal::NotTheIssuer),
            "a sibling"
        );
        assert_eq!(
            may_revoke(5, 3, &l),
            Err(Refusal::NotTheIssuer),
            "its own issuer"
        );
        assert_eq!(
            may_revoke(6, 3, &l),
            Err(Refusal::NotTheIssuer),
            "an ancestor"
        );
        assert_eq!(
            may_revoke(3, 1, &l),
            Err(Refusal::LibraryCredential),
            "the library credential that minted it"
        );
    }

    #[test]
    fn a_corrupted_cycle_is_a_refusal_not_a_hang() {
        let l = HashMap::from([(1, None), (7, Some(8)), (8, Some(7)), (9, Some(1))]);
        assert_eq!(may_revoke(9, 7, &l), Err(Refusal::NotTheIssuer));
        let mut s = subtree(7, &l);
        s.sort_unstable();
        assert_eq!(s, vec![7, 8]);
    }

    #[test]
    fn the_subtree_is_the_target_and_everything_it_minted() {
        let l = library();
        assert_eq!(subtree(3, &l), vec![3, 5, 6]);
        assert_eq!(subtree(4, &l), vec![4]);
        assert_eq!(subtree(1, &l), vec![1, 3, 4, 5, 6]);
    }
}
