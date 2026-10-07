//! The one door to a per-user write. `UserWrite::begin` opens the transaction and allocates the
//! changelog `seq` — taking the user row lock — BEFORE handing the transaction to anyone, so no
//! caller can write an FK-bound row ahead of the lock: the lock-upgrade deadlock Rails hit under
//! concurrent commits is unreachable by construction, not by discipline.

use crate::db::{Db, Query, Tx};
use crate::error::{ApiError, ApiResult};
use crate::models::ChangelogEntry;
use crate::time::Timestamp;

pub struct UserWrite {
    tx: Tx,
    user_id: i64,
    first_seq: i64,
    last_seq: i64,
}

impl UserWrite {
    /// BEGIN (IMMEDIATE on SQLite), lock the user row, allocate the first seq.
    pub async fn begin(db: &Db, user_id: i64) -> ApiResult<Self> {
        let mut tx = db.begin().await?;
        let seq = next_seq(&mut tx, user_id).await?;
        Ok(Self {
            tx,
            user_id,
            first_seq: seq,
            last_seq: seq,
        })
    }

    pub fn user_id(&self) -> i64 {
        self.user_id
    }

    /// The seq allocated at `begin`.
    pub fn seq(&self) -> i64 {
        self.first_seq
    }

    /// The highest seq allocated so far (what a cascade returns).
    pub fn last_seq(&self) -> i64 {
        self.last_seq
    }

    /// A further seq under the same lock — one per node in a cascade, one per split sibling.
    pub async fn next_seq(&mut self) -> ApiResult<i64> {
        let seq = next_seq(&mut self.tx, self.user_id).await?;
        self.last_seq = seq;
        Ok(seq)
    }

    pub fn tx(&mut self) -> &mut Tx {
        &mut self.tx
    }

    /// Append exactly one changelog entry.
    pub async fn append(
        &mut self,
        seq: i64,
        node_id: &str,
        op: &str,
        version_id: Option<&str>,
        now: Timestamp,
    ) -> ApiResult<()> {
        ChangelogEntry::insert(
            &mut self.tx,
            self.user_id,
            seq,
            node_id,
            op,
            version_id,
            now,
        )
        .await?;
        Ok(())
    }

    pub async fn commit(self) -> ApiResult<i64> {
        self.tx.commit().await?;
        Ok(self.last_seq)
    }

    pub async fn rollback(self) -> ApiResult<()> {
        self.tx.rollback().await?;
        Ok(())
    }
}

/// `User#next_seq!`: lock the row, bump `head_seq`, return the new value. On Postgres the lock is
/// `FOR UPDATE`; on SQLite the transaction already holds the writer lock.
async fn next_seq(tx: &mut Tx, user_id: i64) -> ApiResult<i64> {
    let sql = format!(
        "SELECT head_seq FROM users WHERE id = $1{}",
        tx.dialect().for_update()
    );
    let row = tx
        .fetch_optional(&Query::new(sql).bind(user_id))
        .await?
        .ok_or(ApiError::NotFound)?;
    let next = row.i64("head_seq")? + 1;
    tx.execute(
        &Query::new("UPDATE users SET head_seq = $1 WHERE id = $2")
            .bind(next)
            .bind(user_id),
    )
    .await?;
    Ok(next)
}

/// A write that takes the user lock WITHOUT allocating a seq — retention's `prune_version!`,
/// which must serialize against the seq-writers (a restore bumping a chunk it is zeroing).
pub struct UserLock {
    tx: Tx,
}

impl UserLock {
    pub async fn begin(db: &Db, user_id: i64) -> ApiResult<Self> {
        let mut tx = db.begin().await?;
        let sql = format!(
            "SELECT id FROM users WHERE id = $1{}",
            tx.dialect().for_update()
        );
        tx.fetch_optional(&Query::new(sql).bind(user_id))
            .await?
            .ok_or(ApiError::NotFound)?;
        Ok(Self { tx })
    }

    pub fn tx(&mut self) -> &mut Tx {
        &mut self.tx
    }

    pub async fn commit(self) -> ApiResult<()> {
        self.tx.commit().await?;
        Ok(())
    }
}
