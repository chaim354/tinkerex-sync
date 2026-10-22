//! Row types and the query helpers every service shares. Column lists are the Rails schema's;
//! every query is scoped by `user_id` (tenant = user) and written once for both dialects.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::db::{Exec, Query, Row, placeholders};
use crate::time::Timestamp;

/// Binds per `IN (...)`: Postgres caps a statement at 65,535 parameters and a manifest may carry
/// 100,000 hashes, so lookups are sliced (Rails' `HASH_LOOKUP_SLICE`).
pub const HASH_LOOKUP_SLICE: usize = 5_000;

// ---- users ----------------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct User {
    pub id: i64,
    pub email: String,
    pub head_seq: i64,
}

impl User {
    fn from_row(r: &Row) -> sqlx::Result<Self> {
        Ok(Self {
            id: r.i64("id")?,
            email: r.str("email")?,
            head_seq: r.i64("head_seq")?,
        })
    }

    pub async fn find<E: Exec>(e: &mut E, id: i64) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new("SELECT id, email, head_seq FROM users WHERE id = $1").bind(id),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    pub async fn find_by_email<E: Exec>(e: &mut E, email: &str) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new("SELECT id, email, head_seq FROM users WHERE email = $1").bind(email),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    pub async fn create<E: Exec>(e: &mut E, email: &str, now: Timestamp) -> sqlx::Result<Self> {
        let row = e
            .fetch_one(
                &Query::new("INSERT INTO users (email, head_seq, created_at, updated_at) VALUES ($1, 0, $2, $3) RETURNING id")
                    .bind(email)
                    .bind(now)
                    .bind(now),
            )
            .await?;
        Ok(Self {
            id: row.i64("id")?,
            email: email.to_string(),
            head_seq: 0,
        })
    }

    pub async fn count<E: Exec>(e: &mut E) -> sqlx::Result<i64> {
        e.fetch_one(&Query::new("SELECT count(*) AS n FROM users"))
            .await?
            .i64("n")
    }

    pub async fn all_ids<E: Exec>(e: &mut E) -> sqlx::Result<Vec<i64>> {
        e.fetch_all(&Query::new("SELECT id FROM users ORDER BY id"))
            .await?
            .iter()
            .map(|r| r.i64("id"))
            .collect()
    }

    pub async fn head_seq<E: Exec>(e: &mut E, user_id: i64) -> sqlx::Result<i64> {
        e.fetch_one(&Query::new("SELECT head_seq FROM users WHERE id = $1").bind(user_id))
            .await?
            .i64("head_seq")
    }
}

// ---- devices --------------------------------------------------------------------------------

/// What every device read selects, so the struct and the column list cannot drift apart.
const DEVICE_COLUMNS: &str =
    "id, user_id, name, created_at, last_seen_at, issuer_device_id, revoked_at";

/// `last_seen_at` is written at most this often per device. Idle expiry is measured in days, so a
/// clock this coarse moves the expiry instant by minutes; what it saves is a write -- on SQLite,
/// the one writer lock commits queue behind -- on nearly every authenticated read.
pub const LAST_SEEN_RESOLUTION_SECONDS: i64 = 300;

/// A credential, and which of the two kinds it is (`issuer_device_id`, migration 20261022000001):
///   - a LIBRARY credential (`issuer_device_id` NULL) is minted outside the device API -- the
///     operator's `device issue`, or `POST /v1/admin/libraries`, which is how the maker app holds
///     each user's bootstrap token. Nothing can mint another through the API (the admin door
///     refuses an email it already has), so it never idles out and the revoke door never revokes
///     one; only the operator's `device revoke` does. Every row older than the migration reads as
///     one too, because nothing recorded who minted it -- the safe direction, since the maker
///     app's own token is among them;
///   - a DEVICE credential (`issuer_device_id` set) was minted by `POST /v1/devices` with the token
///     of the device it names. It idles out after `DEVICE_IDLE_DAYS`, and revoking it revokes every
///     device it minted in turn (`services::revocation`).
#[derive(Debug, Clone)]
pub struct Device {
    pub id: i64,
    pub user_id: i64,
    pub name: String,
    pub created_at: Timestamp,
    pub last_seen_at: Option<Timestamp>,
    pub issuer_device_id: Option<i64>,
    pub revoked_at: Option<Timestamp>,
}

impl Device {
    fn from_row(r: &Row) -> sqlx::Result<Self> {
        Ok(Self {
            id: r.i64("id")?,
            user_id: r.i64("user_id")?,
            name: r.str("name")?,
            created_at: r.time("created_at")?,
            last_seen_at: r.opt_time("last_seen_at")?,
            issuer_device_id: r.opt_i64("issuer_device_id")?,
            revoked_at: r.opt_time("revoked_at")?,
        })
    }

    pub fn is_library_credential(&self) -> bool {
        self.issuer_device_id.is_none()
    }

    /// The idle clock, the maker app's `Device#last_active_at`: a device never used since it was
    /// minted counts from `created_at`.
    pub fn last_active_at(&self) -> Timestamp {
        self.last_seen_at.unwrap_or(self.created_at)
    }

    /// Unused for longer than `idle_days`. A library credential never idles out (see the type).
    pub fn idled_out(&self, now: Timestamp, idle_days: Option<i64>) -> bool {
        match idle_days {
            Some(days) if !self.is_library_credential() => {
                self.last_active_at() < now.minus_seconds(days * 86_400)
            }
            _ => false,
        }
    }

    /// Whether a request now should move `last_seen_at` (`LAST_SEEN_RESOLUTION_SECONDS`).
    pub fn seen_is_stale(&self, now: Timestamp) -> bool {
        self.last_seen_at
            .is_none_or(|t| t < now.minus_seconds(LAST_SEEN_RESOLUTION_SECONDS))
    }

    pub async fn find_by_digest<E: Exec>(e: &mut E, digest: &str) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new(format!(
                "SELECT {DEVICE_COLUMNS} FROM devices WHERE token_digest = $1"
            ))
            .bind(digest),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    /// By id across every library: the operator's CLI, the cable re-check and the mint's re-read
    /// of its own issuer -- never a lookup of a CLIENT-supplied id, which the revoke door scopes
    /// to the caller's library through `list_for_user`.
    pub async fn find<E: Exec>(e: &mut E, id: i64) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new(format!(
                "SELECT {DEVICE_COLUMNS} FROM devices WHERE id = $1"
            ))
            .bind(id),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    pub async fn create<E: Exec>(
        e: &mut E,
        user_id: i64,
        name: &str,
        digest: &str,
        issuer_device_id: Option<i64>,
        now: Timestamp,
    ) -> sqlx::Result<Self> {
        let row = e
            .fetch_one(
                &Query::new(
                    "INSERT INTO devices (user_id, name, token_digest, issuer_device_id, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
                )
                .bind(user_id)
                .bind(name)
                .bind(digest)
                .bind(issuer_device_id)
                .bind(now)
                .bind(now),
            )
            .await?;
        Ok(Self {
            id: row.i64("id")?,
            user_id,
            name: name.to_string(),
            created_at: now,
            last_seen_at: None,
            issuer_device_id,
            revoked_at: None,
        })
    }

    pub async fn touch_seen<E: Exec>(e: &mut E, id: i64, now: Timestamp) -> sqlx::Result<()> {
        e.execute(
            &Query::new("UPDATE devices SET last_seen_at = $1 WHERE id = $2")
                .bind(now)
                .bind(id),
        )
        .await?;
        Ok(())
    }

    /// Stamp the given devices revoked, once: a row revoked earlier keeps its first `revoked_at`.
    pub async fn mark_revoked<E: Exec>(
        e: &mut E,
        user_id: i64,
        ids: &[i64],
        now: Timestamp,
    ) -> sqlx::Result<u64> {
        if ids.is_empty() {
            return Ok(0);
        }
        let mut q = Query::new(format!(
            "UPDATE devices SET revoked_at = $1, updated_at = $2 WHERE user_id = $3 AND revoked_at IS NULL AND id IN ({})",
            placeholders(4, ids.len())
        ))
        .bind(now)
        .bind(now)
        .bind(user_id);
        for id in ids {
            q = q.bind(*id);
        }
        e.execute(&q).await
    }

    pub async fn name_of<E: Exec>(
        e: &mut E,
        user_id: i64,
        device_id: Option<i64>,
    ) -> sqlx::Result<Option<String>> {
        let Some(device_id) = device_id else {
            return Ok(None);
        };
        e.fetch_optional(
            &Query::new("SELECT name FROM devices WHERE user_id = $1 AND id = $2")
                .bind(user_id)
                .bind(device_id),
        )
        .await?
        .map(|r| r.str("name"))
        .transpose()
    }

    /// Every device of one library, revoked ones included: a user has a handful, and the revoke
    /// door walks their lineage in memory rather than in dialect-specific recursive SQL.
    pub async fn list_for_user<E: Exec>(e: &mut E, user_id: i64) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(
            &Query::new(format!(
                "SELECT {DEVICE_COLUMNS} FROM devices WHERE user_id = $1 ORDER BY id"
            ))
            .bind(user_id),
        )
        .await?
        .iter()
        .map(Self::from_row)
        .collect()
    }
}

// ---- nodes ----------------------------------------------------------------------------------

pub const KIND_FILE: &str = "file";
pub const KIND_DIR: &str = "dir";
pub const KIND_SYMLINK: &str = "symlink";

#[derive(Debug, Clone)]
pub struct Node {
    /// `None` until first saved.
    pub id: Option<i64>,
    pub user_id: i64,
    pub node_id: String,
    pub parent_node_id: Option<String>,
    pub name: String,
    pub kind: String,
    pub deleted: bool,
    pub current_version_id: Option<String>,
    pub mode: Option<i64>,
    pub mtime: Option<i64>,
    pub symlink_target: Option<Vec<u8>>,
    pub updated_seq: i64,
    pub created_at: Timestamp,
    pub updated_at: Timestamp,
}

const NODE_COLUMNS: &str = "id, user_id, node_id, parent_node_id, name, kind, deleted, current_version_id, mode, mtime, symlink_target, updated_seq, created_at, updated_at";

impl Node {
    pub fn new(user_id: i64, node_id: &str, now: Timestamp) -> Self {
        Self {
            id: None,
            user_id,
            node_id: node_id.to_string(),
            parent_node_id: None,
            name: String::new(),
            kind: KIND_FILE.to_string(),
            deleted: false,
            current_version_id: None,
            mode: None,
            mtime: None,
            symlink_target: None,
            updated_seq: 0,
            created_at: now,
            updated_at: now,
        }
    }

    pub fn is_file(&self) -> bool {
        self.kind == KIND_FILE
    }
    pub fn is_symlink(&self) -> bool {
        self.kind == KIND_SYMLINK
    }
    pub fn persisted(&self) -> bool {
        self.id.is_some()
    }

    fn from_row(r: &Row) -> sqlx::Result<Self> {
        Ok(Self {
            id: Some(r.i64("id")?),
            user_id: r.i64("user_id")?,
            node_id: r.str("node_id")?,
            parent_node_id: r.opt_str("parent_node_id")?,
            name: r.str("name")?,
            kind: r.str("kind")?,
            deleted: r.bool("deleted")?,
            current_version_id: r.opt_str("current_version_id")?,
            mode: r.opt_i64("mode")?,
            mtime: r.opt_i64("mtime")?,
            symlink_target: r.opt_bytes("symlink_target")?,
            updated_seq: r.i64("updated_seq")?,
            created_at: r.time("created_at")?,
            updated_at: r.time("updated_at")?,
        })
    }

    pub async fn find<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
    ) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new(format!(
                "SELECT {NODE_COLUMNS} FROM nodes WHERE user_id = $1 AND node_id = $2"
            ))
            .bind(user_id)
            .bind(node_id),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    /// `user.nodes.present.find_by!` — the codebase's one spelling of "live node".
    pub async fn find_present<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
    ) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new(format!("SELECT {NODE_COLUMNS} FROM nodes WHERE user_id = $1 AND node_id = $2 AND deleted = $3"))
                .bind(user_id)
                .bind(node_id)
                .bind(false),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    pub async fn find_present_by_version<E: Exec>(
        e: &mut E,
        user_id: i64,
        version_id: &str,
    ) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new(format!("SELECT {NODE_COLUMNS} FROM nodes WHERE user_id = $1 AND current_version_id = $2 AND deleted = $3 ORDER BY id LIMIT 1"))
                .bind(user_id)
                .bind(version_id)
                .bind(false),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    pub async fn find_many<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_ids: &[String],
    ) -> sqlx::Result<HashMap<String, Self>> {
        let mut out = HashMap::new();
        for slice in node_ids.chunks(HASH_LOOKUP_SLICE) {
            let mut q = Query::new(format!(
                "SELECT {NODE_COLUMNS} FROM nodes WHERE user_id = $1 AND node_id IN ({})",
                placeholders(2, slice.len())
            ))
            .bind(user_id);
            for id in slice {
                q = q.bind(id.as_str());
            }
            for r in e.fetch_all(&q).await? {
                let n = Self::from_row(&r)?;
                out.insert(n.node_id.clone(), n);
            }
        }
        Ok(out)
    }

    /// `Some(parent)` for an existing node (the parent may itself be `None`), `None` for no such node.
    pub async fn parent_of<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
    ) -> sqlx::Result<Option<Option<String>>> {
        e.fetch_optional(
            &Query::new("SELECT parent_node_id FROM nodes WHERE user_id = $1 AND node_id = $2")
                .bind(user_id)
                .bind(node_id),
        )
        .await?
        .map(|r| r.opt_str("parent_node_id"))
        .transpose()
    }

    /// Present children of any of `parents`, excluding ids already seen (the cascade's BFS step).
    pub async fn present_children<E: Exec>(
        e: &mut E,
        user_id: i64,
        parents: &[String],
        seen: &HashSet<String>,
    ) -> sqlx::Result<Vec<Self>> {
        let mut out = Vec::new();
        for slice in parents.chunks(HASH_LOOKUP_SLICE) {
            let mut q = Query::new(format!(
                "SELECT {NODE_COLUMNS} FROM nodes WHERE user_id = $1 AND deleted = $2 AND parent_node_id IN ({}) ORDER BY id",
                placeholders(3, slice.len())
            ))
            .bind(user_id)
            .bind(false);
            for id in slice {
                q = q.bind(id.as_str());
            }
            for r in e.fetch_all(&q).await? {
                let n = Self::from_row(&r)?;
                if !seen.contains(&n.node_id) {
                    out.push(n);
                }
            }
        }
        Ok(out)
    }

    /// The snapshot page: present nodes with `id > after_id`, in id order.
    pub async fn present_page<E: Exec>(
        e: &mut E,
        user_id: i64,
        after_id: i64,
        limit: i64,
    ) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(
            &Query::new(format!("SELECT {NODE_COLUMNS} FROM nodes WHERE user_id = $1 AND deleted = $2 AND id > $3 ORDER BY id LIMIT $4"))
                .bind(user_id)
                .bind(false)
                .bind(after_id)
                .bind(limit),
        )
        .await?
        .iter()
        .map(Self::from_row)
        .collect()
    }

    /// The trash: tombstones, newest-deleted first (`updated_at` is the tombstone time).
    pub async fn trashed<E: Exec>(e: &mut E, user_id: i64) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(
            &Query::new(format!("SELECT {NODE_COLUMNS} FROM nodes WHERE user_id = $1 AND deleted = $2 ORDER BY updated_at DESC, name ASC"))
                .bind(user_id)
                .bind(true),
        )
        .await?
        .iter()
        .map(Self::from_row)
        .collect()
    }

    /// INSERT when new, UPDATE of every column when persisted; `updated_at` always moves, because
    /// every caller that saves a node has changed it (`updated_seq` at the very least).
    pub async fn save<E: Exec>(&mut self, e: &mut E, now: Timestamp) -> sqlx::Result<()> {
        self.updated_at = now;
        match self.id {
            None => {
                self.created_at = now;
                let row = e
                    .fetch_one(
                        &Query::new(
                            "INSERT INTO nodes (user_id, node_id, parent_node_id, name, kind, deleted, current_version_id, mode, mtime, symlink_target, updated_seq, created_at, updated_at) \
                             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) RETURNING id",
                        )
                        .bind(self.user_id)
                        .bind(self.node_id.as_str())
                        .bind(self.parent_node_id.clone())
                        .bind(self.name.as_str())
                        .bind(self.kind.as_str())
                        .bind(self.deleted)
                        .bind(self.current_version_id.clone())
                        .bind(self.mode)
                        .bind(self.mtime)
                        .bind(self.symlink_target.clone())
                        .bind(self.updated_seq)
                        .bind(self.created_at)
                        .bind(self.updated_at),
                    )
                    .await?;
                self.id = Some(row.i64("id")?);
            }
            Some(id) => {
                e.execute(
                    &Query::new(
                        "UPDATE nodes SET parent_node_id = $1, name = $2, kind = $3, deleted = $4, current_version_id = $5, mode = $6, mtime = $7, \
                         symlink_target = $8, updated_seq = $9, updated_at = $10 WHERE id = $11",
                    )
                    .bind(self.parent_node_id.clone())
                    .bind(self.name.as_str())
                    .bind(self.kind.as_str())
                    .bind(self.deleted)
                    .bind(self.current_version_id.clone())
                    .bind(self.mode)
                    .bind(self.mtime)
                    .bind(self.symlink_target.clone())
                    .bind(self.updated_seq)
                    .bind(self.updated_at)
                    .bind(id),
                )
                .await?;
            }
        }
        Ok(())
    }

    pub async fn count<E: Exec>(e: &mut E) -> sqlx::Result<i64> {
        e.fetch_one(&Query::new("SELECT count(*) AS n FROM nodes"))
            .await?
            .i64("n")
    }
}

// ---- versions -------------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Version {
    pub id: Option<i64>,
    pub user_id: i64,
    pub version_id: String,
    pub node_id: String,
    pub manifest_id: String,
    pub size: i64,
    pub device_id: Option<i64>,
    pub parent_version_id: Option<String>,
    pub pinned: bool,
    pub created_at: Timestamp,
}

const VERSION_COLUMNS: &str = "id, user_id, version_id, node_id, manifest_id, size, device_id, parent_version_id, pinned, created_at";

impl Version {
    fn from_row(r: &Row) -> sqlx::Result<Self> {
        Ok(Self {
            id: Some(r.i64("id")?),
            user_id: r.i64("user_id")?,
            version_id: r.str("version_id")?,
            node_id: r.str("node_id")?,
            manifest_id: r.str("manifest_id")?,
            size: r.i64("size")?,
            device_id: r.opt_i64("device_id")?,
            parent_version_id: r.opt_str("parent_version_id")?,
            pinned: r.bool("pinned")?,
            created_at: r.time("created_at")?,
        })
    }

    pub async fn find<E: Exec>(
        e: &mut E,
        user_id: i64,
        version_id: &str,
    ) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new(format!(
                "SELECT {VERSION_COLUMNS} FROM versions WHERE user_id = $1 AND version_id = $2"
            ))
            .bind(user_id)
            .bind(version_id),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    pub async fn find_for_node<E: Exec>(
        e: &mut E,
        user_id: i64,
        version_id: &str,
        node_id: &str,
    ) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new(format!("SELECT {VERSION_COLUMNS} FROM versions WHERE user_id = $1 AND version_id = $2 AND node_id = $3"))
                .bind(user_id)
                .bind(version_id)
                .bind(node_id),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    pub async fn find_many<E: Exec>(
        e: &mut E,
        user_id: i64,
        version_ids: &[String],
    ) -> sqlx::Result<HashMap<String, Self>> {
        let mut out = HashMap::new();
        for slice in version_ids.chunks(HASH_LOOKUP_SLICE) {
            let mut q = Query::new(format!(
                "SELECT {VERSION_COLUMNS} FROM versions WHERE user_id = $1 AND version_id IN ({})",
                placeholders(2, slice.len())
            ))
            .bind(user_id);
            for id in slice {
                q = q.bind(id.as_str());
            }
            for r in e.fetch_all(&q).await? {
                let v = Self::from_row(&r)?;
                out.insert(v.version_id.clone(), v);
            }
        }
        Ok(out)
    }

    /// `version_id => size` for a set of ids, in one query per slice; a missing version is an
    /// absent key, never an error (the caller holds a list, and a row that vanished mid-page must
    /// not take the page down).
    pub async fn sizes<E: Exec>(
        e: &mut E,
        user_id: i64,
        version_ids: &[String],
    ) -> sqlx::Result<HashMap<String, i64>> {
        Ok(Self::find_many(e, user_id, version_ids)
            .await?
            .into_iter()
            .map(|(k, v)| (k, v.size))
            .collect())
    }

    pub async fn insert<E: Exec>(&mut self, e: &mut E) -> sqlx::Result<()> {
        let row = e
            .fetch_one(
                &Query::new(
                    "INSERT INTO versions (user_id, version_id, node_id, manifest_id, size, device_id, parent_version_id, pinned, created_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id",
                )
                .bind(self.user_id)
                .bind(self.version_id.as_str())
                .bind(self.node_id.as_str())
                .bind(self.manifest_id.as_str())
                .bind(self.size)
                .bind(self.device_id)
                .bind(self.parent_version_id.clone())
                .bind(self.pinned)
                .bind(self.created_at),
            )
            .await?;
        self.id = Some(row.i64("id")?);
        Ok(())
    }

    /// Newest first, capped — `GET /v1/nodes/:id/versions`.
    pub async fn list_for_node<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
        limit: i64,
    ) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(
            &Query::new(format!("SELECT {VERSION_COLUMNS} FROM versions WHERE user_id = $1 AND node_id = $2 ORDER BY id DESC LIMIT $3"))
                .bind(user_id)
                .bind(node_id)
                .bind(limit),
        )
        .await?
        .iter()
        .map(Self::from_row)
        .collect()
    }

    pub async fn all_for_node<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
    ) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(&Query::new(format!("SELECT {VERSION_COLUMNS} FROM versions WHERE user_id = $1 AND node_id = $2 ORDER BY id")).bind(user_id).bind(node_id))
            .await?
            .iter()
            .map(Self::from_row)
            .collect()
    }

    pub async fn node_ids_with_versions<E: Exec>(
        e: &mut E,
        user_id: i64,
    ) -> sqlx::Result<Vec<String>> {
        e.fetch_all(
            &Query::new("SELECT DISTINCT node_id FROM versions WHERE user_id = $1").bind(user_id),
        )
        .await?
        .iter()
        .map(|r| r.str("node_id"))
        .collect()
    }

    /// The retention claim: rows removed, which is 1 for exactly one of two overlapping passes.
    pub async fn delete_by_version_id<E: Exec>(
        e: &mut E,
        user_id: i64,
        version_id: &str,
    ) -> sqlx::Result<u64> {
        e.execute(
            &Query::new("DELETE FROM versions WHERE user_id = $1 AND version_id = $2")
                .bind(user_id)
                .bind(version_id),
        )
        .await
    }

    pub async fn count<E: Exec>(e: &mut E) -> sqlx::Result<i64> {
        e.fetch_one(&Query::new("SELECT count(*) AS n FROM versions"))
            .await?
            .i64("n")
    }
}

// ---- manifest_chunks ------------------------------------------------------------------------

/// One entry of a manifest, on the wire and in `pending_commits.manifest_json`. Field order is the
/// order Rails serialized (`hash`, `offset`, `length`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChunkRef {
    pub hash: String,
    pub offset: i64,
    pub length: i64,
}

pub async fn manifest_exists<E: Exec>(
    e: &mut E,
    user_id: i64,
    manifest_id: &str,
) -> sqlx::Result<bool> {
    let row = e
        .fetch_one(
            &Query::new(
                "SELECT count(*) AS n FROM manifest_chunks WHERE user_id = $1 AND manifest_id = $2",
            )
            .bind(user_id)
            .bind(manifest_id),
        )
        .await?;
    Ok(row.i64("n")? > 0)
}

pub async fn insert_manifest<E: Exec>(
    e: &mut E,
    user_id: i64,
    manifest_id: &str,
    entries: &[ChunkRef],
) -> sqlx::Result<()> {
    for (seq, c) in entries.iter().enumerate() {
        e.execute(
            &Query::new("INSERT INTO manifest_chunks (user_id, manifest_id, seq, chunk_hash, \"offset\", length) VALUES ($1, $2, $3, $4, $5, $6)")
                .bind(user_id)
                .bind(manifest_id)
                .bind(seq as i64)
                .bind(c.hash.as_str())
                .bind(c.offset)
                .bind(c.length),
        )
        .await?;
    }
    Ok(())
}

/// `manifest_id => [chunk, ...]` ordered by `seq`, for a SET of manifest ids in one query per slice.
pub async fn load_manifests<E: Exec>(
    e: &mut E,
    user_id: i64,
    manifest_ids: &[String],
) -> sqlx::Result<HashMap<String, Vec<ChunkRef>>> {
    let mut out: HashMap<String, Vec<ChunkRef>> = HashMap::new();
    let mut ids: Vec<&String> = manifest_ids.iter().collect();
    ids.sort();
    ids.dedup();
    for slice in ids.chunks(HASH_LOOKUP_SLICE) {
        let mut q = Query::new(format!(
            "SELECT manifest_id, chunk_hash, \"offset\", length FROM manifest_chunks WHERE user_id = $1 AND manifest_id IN ({}) ORDER BY manifest_id, seq",
            placeholders(2, slice.len())
        ))
        .bind(user_id);
        for id in slice {
            q = q.bind(id.as_str());
        }
        for r in e.fetch_all(&q).await? {
            out.entry(r.str("manifest_id")?)
                .or_default()
                .push(ChunkRef {
                    hash: r.str("chunk_hash")?,
                    offset: r.i64("offset")?,
                    length: r.i64("length")?,
                });
        }
    }
    Ok(out)
}

/// Distinct chunk hashes of one manifest.
pub async fn manifest_hashes<E: Exec>(
    e: &mut E,
    user_id: i64,
    manifest_id: &str,
) -> sqlx::Result<Vec<String>> {
    e.fetch_all(&Query::new("SELECT DISTINCT chunk_hash FROM manifest_chunks WHERE user_id = $1 AND manifest_id = $2").bind(user_id).bind(manifest_id))
        .await?
        .iter()
        .map(|r| r.str("chunk_hash"))
        .collect()
}

pub async fn manifest_hash_set<E: Exec>(
    e: &mut E,
    user_id: i64,
    manifest_id: &str,
) -> sqlx::Result<HashSet<String>> {
    Ok(manifest_hashes(e, user_id, manifest_id)
        .await?
        .into_iter()
        .collect())
}

// ---- chunks ---------------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Chunk {
    pub id: i64,
    pub chunk_hash: String,
    pub refcount: i64,
    pub size: i64,
    pub updated_at: Timestamp,
}

/// Which of `hashes` this user already has a row for.
pub async fn known_chunk_hashes<E: Exec>(
    e: &mut E,
    user_id: i64,
    hashes: &[String],
) -> sqlx::Result<HashSet<String>> {
    let mut out = HashSet::new();
    for slice in hashes.chunks(HASH_LOOKUP_SLICE) {
        let mut q = Query::new(format!(
            "SELECT chunk_hash FROM chunks WHERE user_id = $1 AND chunk_hash IN ({})",
            placeholders(2, slice.len())
        ))
        .bind(user_id);
        for h in slice {
            q = q.bind(h.as_str());
        }
        for r in e.fetch_all(&q).await? {
            out.insert(r.str("chunk_hash")?);
        }
    }
    Ok(out)
}

/// New chunk rows start at refcount 1.
pub async fn insert_chunks<E: Exec>(
    e: &mut E,
    user_id: i64,
    rows: &[(String, i64)],
    now: Timestamp,
) -> sqlx::Result<()> {
    for (hash, size) in rows {
        e.execute(
            &Query::new("INSERT INTO chunks (user_id, chunk_hash, size, refcount, created_at, updated_at) VALUES ($1, $2, $3, 1, $4, $5)")
                .bind(user_id)
                .bind(hash.as_str())
                .bind(*size)
                .bind(now)
                .bind(now),
        )
        .await?;
    }
    Ok(())
}

/// THE ONE PLACE A REFCOUNT MOVES, and `updated_at` moves with it every time: the orphan sweep's
/// grace window filters on `updated_at`, so a refcount write that left it behind would test a
/// chunk's creation age instead of its zeroing age (a recorded data-loss bug). `only_positive`
/// adds Rails' `WHERE refcount > 0` guard for decrements.
pub async fn touch_refcounts<E: Exec>(
    e: &mut E,
    user_id: i64,
    hashes: &[String],
    delta: i64,
    now: Timestamp,
    only_positive: bool,
) -> sqlx::Result<()> {
    for slice in hashes.chunks(HASH_LOOKUP_SLICE) {
        let guard = if only_positive {
            " AND refcount > 0"
        } else {
            ""
        };
        let mut q = Query::new(format!(
            "UPDATE chunks SET refcount = refcount + $1, updated_at = $2 WHERE user_id = $3 AND chunk_hash IN ({}){guard}",
            placeholders(4, slice.len())
        ))
        .bind(delta)
        .bind(now)
        .bind(user_id);
        for h in slice {
            q = q.bind(h.as_str());
        }
        e.execute(&q).await?;
    }
    Ok(())
}

/// Chunks at refcount <= 0 whose last refcount touch is at or before `cutoff`.
pub async fn zeroed_chunks_before<E: Exec>(
    e: &mut E,
    user_id: i64,
    cutoff: Timestamp,
) -> sqlx::Result<Vec<Chunk>> {
    e.fetch_all(
        &Query::new("SELECT id, chunk_hash, refcount, size, updated_at FROM chunks WHERE user_id = $1 AND refcount <= 0 AND updated_at <= $2 ORDER BY id")
            .bind(user_id)
            .bind(cutoff),
    )
    .await?
    .iter()
    .map(|r| Ok(Chunk { id: r.i64("id")?, chunk_hash: r.str("chunk_hash")?, refcount: r.i64("refcount")?, size: r.i64("size")?, updated_at: r.time("updated_at")? }))
    .collect()
}

/// Compare-and-delete: the row is the claim, and a concurrent bumper's UPDATE and this DELETE
/// cannot both win.
pub async fn delete_chunk_if_zero<E: Exec>(e: &mut E, id: i64) -> sqlx::Result<u64> {
    e.execute(&Query::new("DELETE FROM chunks WHERE id = $1 AND refcount <= 0").bind(id))
        .await
}

pub async fn chunk_count<E: Exec>(e: &mut E) -> sqlx::Result<i64> {
    e.fetch_one(&Query::new("SELECT count(*) AS n FROM chunks"))
        .await?
        .i64("n")
}

// ---- changelog_entries ----------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct ChangelogEntry {
    pub seq: i64,
    pub node_id: String,
    pub op: String,
    pub version_id: Option<String>,
}

impl ChangelogEntry {
    pub async fn insert<E: Exec>(
        e: &mut E,
        user_id: i64,
        seq: i64,
        node_id: &str,
        op: &str,
        version_id: Option<&str>,
        now: Timestamp,
    ) -> sqlx::Result<()> {
        e.execute(
            &Query::new("INSERT INTO changelog_entries (user_id, seq, node_id, op, version_id, created_at) VALUES ($1, $2, $3, $4, $5, $6)")
                .bind(user_id)
                .bind(seq)
                .bind(node_id)
                .bind(op)
                .bind(version_id)
                .bind(now),
        )
        .await?;
        Ok(())
    }

    pub async fn since<E: Exec>(
        e: &mut E,
        user_id: i64,
        since: i64,
        limit: i64,
    ) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(
            &Query::new("SELECT seq, node_id, op, version_id FROM changelog_entries WHERE user_id = $1 AND seq > $2 ORDER BY seq LIMIT $3")
                .bind(user_id)
                .bind(since)
                .bind(limit),
        )
        .await?
        .iter()
        .map(|r| Ok(Self { seq: r.i64("seq")?, node_id: r.str("node_id")?, op: r.str("op")?, version_id: r.opt_str("version_id")? }))
        .collect()
    }

    pub async fn min_seq<E: Exec>(e: &mut E, user_id: i64) -> sqlx::Result<Option<i64>> {
        e.fetch_one(
            &Query::new("SELECT min(seq) AS m FROM changelog_entries WHERE user_id = $1")
                .bind(user_id),
        )
        .await?
        .opt_i64("m")
    }

    pub async fn prune_through<E: Exec>(
        e: &mut E,
        user_id: i64,
        keep_after: i64,
    ) -> sqlx::Result<u64> {
        e.execute(
            &Query::new("DELETE FROM changelog_entries WHERE user_id = $1 AND seq <= $2")
                .bind(user_id)
                .bind(keep_after),
        )
        .await
    }

    pub async fn count<E: Exec>(e: &mut E) -> sqlx::Result<i64> {
        e.fetch_one(&Query::new("SELECT count(*) AS n FROM changelog_entries"))
            .await?
            .i64("n")
    }
}

// ---- pending_commits ------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct PendingCommit {
    pub id: i64,
    pub user_id: i64,
    pub commit_id: String,
    pub node_id: String,
    pub parent_node_id: Option<String>,
    pub name: String,
    pub manifest_id: String,
    pub manifest_json: String,
    pub base_version_id: Option<String>,
    pub size: i64,
    pub mode: Option<i64>,
    pub mtime: Option<i64>,
    pub device_id: Option<i64>,
    pub created_at: Timestamp,
}

const PENDING_COLUMNS: &str = "id, user_id, commit_id, node_id, parent_node_id, name, manifest_id, manifest_json, base_version_id, size, mode, mtime, device_id, created_at";

pub struct PendingFields<'a> {
    pub node_id: &'a str,
    pub parent_node_id: Option<&'a str>,
    pub name: &'a str,
    pub manifest_id: &'a str,
    pub manifest_json: &'a str,
    pub base_version_id: Option<&'a str>,
    pub size: i64,
    pub mode: Option<i64>,
    pub mtime: Option<i64>,
    pub device_id: Option<i64>,
}

impl PendingCommit {
    fn from_row(r: &Row) -> sqlx::Result<Self> {
        Ok(Self {
            id: r.i64("id")?,
            user_id: r.i64("user_id")?,
            commit_id: r.str("commit_id")?,
            node_id: r.str("node_id")?,
            parent_node_id: r.opt_str("parent_node_id")?,
            name: r.str("name")?,
            manifest_id: r.str("manifest_id")?,
            manifest_json: r.str("manifest_json")?,
            base_version_id: r.opt_str("base_version_id")?,
            size: r.i64("size")?,
            mode: r.opt_i64("mode")?,
            mtime: r.opt_i64("mtime")?,
            device_id: r.opt_i64("device_id")?,
            created_at: r.time("created_at")?,
        })
    }

    /// The staged manifest. A row a hostile client staged with an unparseable manifest is the
    /// reaper's problem to log and skip, so this returns the parse error rather than panicking.
    pub fn manifest(&self) -> Result<Vec<ChunkRef>, serde_json::Error> {
        serde_json::from_str(&self.manifest_json)
    }

    pub async fn find<E: Exec>(
        e: &mut E,
        user_id: i64,
        commit_id: &str,
    ) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(&Query::new(format!("SELECT {PENDING_COLUMNS} FROM pending_commits WHERE user_id = $1 AND commit_id = $2")).bind(user_id).bind(commit_id))
            .await?
            .map(|r| Self::from_row(&r))
            .transpose()
    }

    /// `find_or_initialize_by(commit_id:)` then assign everything: a retry with identical
    /// parameters is indistinguishable from one call; a retry with different ones replaces.
    pub async fn upsert<E: Exec>(
        e: &mut E,
        user_id: i64,
        commit_id: &str,
        f: &PendingFields<'_>,
        now: Timestamp,
    ) -> sqlx::Result<()> {
        let existing = e
            .fetch_optional(
                &Query::new("SELECT id FROM pending_commits WHERE user_id = $1 AND commit_id = $2")
                    .bind(user_id)
                    .bind(commit_id),
            )
            .await?;
        match existing {
            Some(row) => {
                e.execute(
                    &Query::new(
                        "UPDATE pending_commits SET node_id = $1, parent_node_id = $2, name = $3, manifest_id = $4, manifest_json = $5, base_version_id = $6, \
                         size = $7, mode = $8, mtime = $9, device_id = $10, updated_at = $11 WHERE id = $12",
                    )
                    .bind(f.node_id)
                    .bind(f.parent_node_id)
                    .bind(f.name)
                    .bind(f.manifest_id)
                    .bind(f.manifest_json)
                    .bind(f.base_version_id)
                    .bind(f.size)
                    .bind(f.mode)
                    .bind(f.mtime)
                    .bind(f.device_id)
                    .bind(now)
                    .bind(row.i64("id")?),
                )
                .await?;
            }
            None => {
                e.execute(
                    &Query::new(
                        "INSERT INTO pending_commits (user_id, commit_id, node_id, parent_node_id, name, manifest_id, manifest_json, base_version_id, size, mode, mtime, device_id, created_at, updated_at) \
                         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)",
                    )
                    .bind(user_id)
                    .bind(commit_id)
                    .bind(f.node_id)
                    .bind(f.parent_node_id)
                    .bind(f.name)
                    .bind(f.manifest_id)
                    .bind(f.manifest_json)
                    .bind(f.base_version_id)
                    .bind(f.size)
                    .bind(f.mode)
                    .bind(f.mtime)
                    .bind(f.device_id)
                    .bind(now)
                    .bind(now),
                )
                .await?;
            }
        }
        Ok(())
    }

    pub async fn delete<E: Exec>(e: &mut E, id: i64) -> sqlx::Result<()> {
        e.execute(&Query::new("DELETE FROM pending_commits WHERE id = $1").bind(id))
            .await?;
        Ok(())
    }

    pub async fn all_for_user<E: Exec>(e: &mut E, user_id: i64) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(
            &Query::new(format!(
                "SELECT {PENDING_COLUMNS} FROM pending_commits WHERE user_id = $1 ORDER BY id"
            ))
            .bind(user_id),
        )
        .await?
        .iter()
        .map(Self::from_row)
        .collect()
    }

    pub async fn created_before<E: Exec>(
        e: &mut E,
        user_id: i64,
        cutoff: Timestamp,
    ) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(&Query::new(format!("SELECT {PENDING_COLUMNS} FROM pending_commits WHERE user_id = $1 AND created_at < $2 ORDER BY id")).bind(user_id).bind(cutoff))
            .await?
            .iter()
            .map(Self::from_row)
            .collect()
    }

    pub async fn created_at_or_after<E: Exec>(
        e: &mut E,
        user_id: i64,
        cutoff: Timestamp,
    ) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(&Query::new(format!("SELECT {PENDING_COLUMNS} FROM pending_commits WHERE user_id = $1 AND created_at >= $2 ORDER BY id")).bind(user_id).bind(cutoff))
            .await?
            .iter()
            .map(Self::from_row)
            .collect()
    }

    pub async fn delete_ids<E: Exec>(e: &mut E, ids: &[i64]) -> sqlx::Result<()> {
        for slice in ids.chunks(HASH_LOOKUP_SLICE) {
            let mut q = Query::new(format!(
                "DELETE FROM pending_commits WHERE id IN ({})",
                placeholders(1, slice.len())
            ));
            for id in slice {
                q = q.bind(*id);
            }
            e.execute(&q).await?;
        }
        Ok(())
    }
}

// ---- conflicts ------------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Conflict {
    pub id: i64,
    pub node_id: String,
    pub incoming_version_id: String,
    pub current_version_id: String,
    pub created_at: Timestamp,
}

impl Conflict {
    fn from_row(r: &Row) -> sqlx::Result<Self> {
        Ok(Self {
            id: r.i64("id")?,
            node_id: r.str("node_id")?,
            incoming_version_id: r.str("incoming_version_id")?,
            current_version_id: r.str("current_version_id")?,
            created_at: r.time("created_at")?,
        })
    }

    pub async fn unresolved_all<E: Exec>(e: &mut E, user_id: i64) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(
            &Query::new("SELECT id, node_id, incoming_version_id, current_version_id, created_at FROM conflicts WHERE user_id = $1 AND resolved_at IS NULL ORDER BY created_at, id")
                .bind(user_id),
        )
        .await?
        .iter()
        .map(Self::from_row)
        .collect()
    }

    pub async fn unresolved_for_node<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
    ) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(
            &Query::new("SELECT id, node_id, incoming_version_id, current_version_id, created_at FROM conflicts WHERE user_id = $1 AND node_id = $2 AND resolved_at IS NULL ORDER BY created_at, id")
                .bind(user_id)
                .bind(node_id),
        )
        .await?
        .iter()
        .map(Self::from_row)
        .collect()
    }

    /// `user.conflicts.unresolved.find_or_initialize_by(node_id:, incoming_version_id:)`, then
    /// `current_version_id = prior_current; save!` — one row per divergent incoming version.
    pub async fn record<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
        incoming: &str,
        current: &str,
        now: Timestamp,
    ) -> sqlx::Result<()> {
        let existing = e
            .fetch_optional(
                &Query::new("SELECT id FROM conflicts WHERE user_id = $1 AND node_id = $2 AND incoming_version_id = $3 AND resolved_at IS NULL")
                    .bind(user_id)
                    .bind(node_id)
                    .bind(incoming),
            )
            .await?;
        match existing {
            Some(row) => {
                e.execute(&Query::new("UPDATE conflicts SET current_version_id = $1, updated_at = $2 WHERE id = $3").bind(current).bind(now).bind(row.i64("id")?))
                    .await?;
            }
            None => {
                e.execute(
                    &Query::new(
                        "INSERT INTO conflicts (user_id, node_id, incoming_version_id, current_version_id, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)",
                    )
                    .bind(user_id)
                    .bind(node_id)
                    .bind(incoming)
                    .bind(current)
                    .bind(now)
                    .bind(now),
                )
                .await?;
            }
        }
        Ok(())
    }

    pub async fn resolve_node<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
        now: Timestamp,
    ) -> sqlx::Result<u64> {
        e.execute(&Query::new("UPDATE conflicts SET resolved_at = $1 WHERE user_id = $2 AND node_id = $3 AND resolved_at IS NULL").bind(now).bind(user_id).bind(node_id))
            .await
    }
}

// ---- file_locks -----------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct FileLock {
    pub id: i64,
    pub node_id: String,
    pub device_id: i64,
    pub expires_at: Timestamp,
}

impl FileLock {
    fn from_row(r: &Row) -> sqlx::Result<Self> {
        Ok(Self {
            id: r.i64("id")?,
            node_id: r.str("node_id")?,
            device_id: r.i64("device_id")?,
            expires_at: r.time("expires_at")?,
        })
    }

    pub async fn find<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
    ) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(&Query::new("SELECT id, node_id, device_id, expires_at FROM file_locks WHERE user_id = $1 AND node_id = $2").bind(user_id).bind(node_id))
            .await?
            .map(|r| Self::from_row(&r))
            .transpose()
    }

    pub async fn insert<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
        device_id: i64,
        expires_at: Timestamp,
        now: Timestamp,
    ) -> sqlx::Result<()> {
        e.execute(
            &Query::new("INSERT INTO file_locks (user_id, node_id, device_id, expires_at, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)")
                .bind(user_id)
                .bind(node_id)
                .bind(device_id)
                .bind(expires_at)
                .bind(now)
                .bind(now),
        )
        .await?;
        Ok(())
    }

    pub async fn update<E: Exec>(
        e: &mut E,
        id: i64,
        device_id: i64,
        expires_at: Timestamp,
        now: Timestamp,
    ) -> sqlx::Result<()> {
        e.execute(&Query::new("UPDATE file_locks SET device_id = $1, expires_at = $2, updated_at = $3 WHERE id = $4").bind(device_id).bind(expires_at).bind(now).bind(id))
            .await?;
        Ok(())
    }

    pub async fn delete<E: Exec>(e: &mut E, id: i64) -> sqlx::Result<()> {
        e.execute(&Query::new("DELETE FROM file_locks WHERE id = $1").bind(id))
            .await?;
        Ok(())
    }

    pub async fn active<E: Exec>(
        e: &mut E,
        user_id: i64,
        now: Timestamp,
    ) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(&Query::new("SELECT id, node_id, device_id, expires_at FROM file_locks WHERE user_id = $1 AND expires_at > $2 ORDER BY id").bind(user_id).bind(now))
            .await?
            .iter()
            .map(Self::from_row)
            .collect()
    }
}

// ---- share_links ----------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct ShareLink {
    pub id: i64,
    pub user_id: i64,
    pub node_id: String,
    pub version_id: String,
    pub manifest_id: String,
    pub expires_at: Option<Timestamp>,
    pub revoked_at: Option<Timestamp>,
}

const SHARE_LINK_COLUMNS: &str =
    "id, user_id, node_id, version_id, manifest_id, expires_at, revoked_at";

impl ShareLink {
    fn from_row(r: &Row) -> sqlx::Result<Self> {
        Ok(Self {
            id: r.i64("id")?,
            user_id: r.i64("user_id")?,
            node_id: r.str("node_id")?,
            version_id: r.str("version_id")?,
            manifest_id: r.str("manifest_id")?,
            expires_at: r.opt_time("expires_at")?,
            revoked_at: r.opt_time("revoked_at")?,
        })
    }

    /// Not revoked and not past its expiry.
    pub fn live(&self, now: Timestamp) -> bool {
        self.revoked_at.is_none() && self.expires_at.map(|t| t > now).unwrap_or(true)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn create<E: Exec>(
        e: &mut E,
        user_id: i64,
        node_id: &str,
        version_id: &str,
        manifest_id: &str,
        token_digest: &str,
        expires_at: Option<Timestamp>,
        now: Timestamp,
    ) -> sqlx::Result<Self> {
        let row = e
            .fetch_one(
                &Query::new(
                    "INSERT INTO share_links (user_id, node_id, version_id, manifest_id, token_digest, expires_at, created_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
                )
                .bind(user_id)
                .bind(node_id)
                .bind(version_id)
                .bind(manifest_id)
                .bind(token_digest)
                .bind(expires_at)
                .bind(now)
                .bind(now),
            )
            .await?;
        Ok(Self {
            id: row.i64("id")?,
            user_id,
            node_id: node_id.to_string(),
            version_id: version_id.to_string(),
            manifest_id: manifest_id.to_string(),
            expires_at,
            revoked_at: None,
        })
    }

    pub async fn find_by_digest<E: Exec>(e: &mut E, digest: &str) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new(format!(
                "SELECT {SHARE_LINK_COLUMNS} FROM share_links WHERE token_digest = $1"
            ))
            .bind(digest),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    pub async fn find_owned<E: Exec>(
        e: &mut E,
        user_id: i64,
        id: i64,
    ) -> sqlx::Result<Option<Self>> {
        e.fetch_optional(
            &Query::new(format!(
                "SELECT {SHARE_LINK_COLUMNS} FROM share_links WHERE user_id = $1 AND id = $2"
            ))
            .bind(user_id)
            .bind(id),
        )
        .await?
        .map(|r| Self::from_row(&r))
        .transpose()
    }

    pub async fn revoke<E: Exec>(e: &mut E, id: i64, now: Timestamp) -> sqlx::Result<()> {
        e.execute(
            &Query::new("UPDATE share_links SET revoked_at = $1, updated_at = $2 WHERE id = $3")
                .bind(now)
                .bind(now)
                .bind(id),
        )
        .await?;
        Ok(())
    }

    pub async fn all_for_user<E: Exec>(e: &mut E, user_id: i64) -> sqlx::Result<Vec<Self>> {
        e.fetch_all(
            &Query::new(format!(
                "SELECT {SHARE_LINK_COLUMNS} FROM share_links WHERE user_id = $1 ORDER BY id"
            ))
            .bind(user_id),
        )
        .await?
        .iter()
        .map(Self::from_row)
        .collect()
    }
}
