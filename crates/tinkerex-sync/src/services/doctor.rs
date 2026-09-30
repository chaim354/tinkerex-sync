//! The Postgres connection-pooler probe (`Sync::PostgresPoolerCheck`), as the `doctor`
//! subcommand and an optional boot check.
//!
//! WHY: every mutation allocates its changelog seq under a `SELECT ... FOR UPDATE` row lock that
//! must span the read and the write of `users.head_seq` inside ONE transaction on ONE backend
//! connection. A pooler in STATEMENT mode (PgBouncer, RDS Proxy, Supabase) may hand each
//! statement a different backend, which silently breaks the lock and lets two commits allocate
//! the same seq. Session or transaction pooling is fine. The probe opens a transaction and checks
//! that two statements see the same backend pid AND that a session advisory lock taken by the
//! first is still held at the second; under statement pooling they diverge.
//!
//! OFF BY DEFAULT AT BOOT, deliberately: a probe that refuses to start takes a deployment down
//! exactly when it is misconfigured, which is its job and not a switch to flip in passing
//! (CLAUDE.md §2). `SYNC_DB_POOLER_CHECK=refuse` turns the refusal on; the default warns.

use crate::db::{Db, Dialect, Query};

pub const ADVISORY_KEY: i64 = 424242;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeResult {
    pub ok: bool,
    pub same_backend: bool,
    pub lock_held: bool,
    pub error: Option<String>,
}

/// What `serve` does with a failed probe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PoolerCheck {
    /// Log a warning and boot (the default).
    Warn,
    /// Refuse to boot.
    Refuse,
    /// Do not probe at all (`DB_SKIP_POOLER_CHECK=1`, the Rails host's own escape hatch, or
    /// `SYNC_DB_POOLER_CHECK=skip`).
    Skip,
}

impl PoolerCheck {
    pub fn from_lookup(get: &dyn Fn(&str) -> Option<String>) -> Self {
        if get("DB_SKIP_POOLER_CHECK").as_deref() == Some("1") {
            return PoolerCheck::Skip;
        }
        match get("SYNC_DB_POOLER_CHECK").as_deref().map(str::trim) {
            Some("refuse") => PoolerCheck::Refuse,
            Some("skip") | Some("off") | Some("0") => PoolerCheck::Skip,
            _ => PoolerCheck::Warn,
        }
    }
}

/// `None` on SQLite — there is no pooler to probe and nothing to say.
pub async fn probe(db: &Db) -> Option<ProbeResult> {
    if !matches!(db.dialect(), Dialect::Postgres) {
        return None;
    }
    Some(run(db).await)
}

async fn run(db: &Db) -> ProbeResult {
    let mut same_backend = false;
    let mut lock_held = false;
    let attempt: anyhow::Result<()> = async {
        let mut tx = db.begin().await?;
        let pid1 = tx
            .fetch_one(&Query::new("SELECT pg_backend_pid() AS pid"))
            .await?
            .i64("pid")?;
        tx.execute(&Query::new(format!("SELECT pg_advisory_lock({ADVISORY_KEY})")))
            .await?;
        let pid2 = tx
            .fetch_one(&Query::new("SELECT pg_backend_pid() AS pid"))
            .await?
            .i64("pid")?;
        let held = tx
            .fetch_one(&Query::new(format!(
                "SELECT count(*) AS n FROM pg_locks WHERE locktype = 'advisory' \
                 AND ((classid::bigint << 32) | objid::bigint) = {ADVISORY_KEY} AND pid = pg_backend_pid()"
            )))
            .await?
            .i64("n")?;
        tx.execute(&Query::new(format!(
            "SELECT pg_advisory_unlock({ADVISORY_KEY})"
        )))
        .await?;
        tx.commit().await?;
        same_backend = pid1 == pid2;
        lock_held = held >= 1;
        Ok(())
    }
    .await;
    match attempt {
        Ok(()) => ProbeResult {
            ok: same_backend && lock_held,
            same_backend,
            lock_held,
            error: None,
        },
        Err(e) => ProbeResult {
            ok: false,
            same_backend,
            lock_held,
            error: Some(e.to_string()),
        },
    }
}

pub fn failure_message(r: &ProbeResult) -> String {
    let cause = match &r.error {
        Some(e) => format!("the probe itself failed: {e}"),
        None => format!(
            "statements in one transaction did not stay on a single backend connection \
             (same_backend={} advisory_lock_held={})",
            r.same_backend, r.lock_held
        ),
    };
    format!(
        "[postgres-pooler-check] Detected a STATEMENT-mode connection pooler in front of Postgres \
         ({cause}). This server's changelog sequence allocator (next_seq, the FOR UPDATE row lock \
         on users) needs a lock that spans one TRANSACTION; statement-mode pooling silently breaks \
         it and can corrupt the changelog with duplicate seqs. Use SESSION or TRANSACTION pool \
         mode (PgBouncer pool_mode=transaction, RDS Proxy / Supabase transaction mode). Set \
         SYNC_DB_POOLER_CHECK=skip (or DB_SKIP_POOLER_CHECK=1) to bypass once you have verified \
         the pooler mode independently."
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn mode(pairs: &[(&str, &str)]) -> PoolerCheck {
        let env: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        PoolerCheck::from_lookup(&|k| env.get(k).cloned())
    }

    #[test]
    fn the_default_warns_and_the_two_escape_hatches_skip() {
        assert_eq!(mode(&[]), PoolerCheck::Warn);
        assert_eq!(
            mode(&[("SYNC_DB_POOLER_CHECK", "refuse")]),
            PoolerCheck::Refuse
        );
        assert_eq!(mode(&[("SYNC_DB_POOLER_CHECK", "skip")]), PoolerCheck::Skip);
        assert_eq!(mode(&[("DB_SKIP_POOLER_CHECK", "1")]), PoolerCheck::Skip);
        assert_eq!(
            mode(&[
                ("DB_SKIP_POOLER_CHECK", "1"),
                ("SYNC_DB_POOLER_CHECK", "refuse")
            ]),
            PoolerCheck::Skip,
            "the Rails host's own bypass still wins"
        );
    }

    #[test]
    fn failure_message_names_the_risk_and_the_fix() {
        let msg = failure_message(&ProbeResult {
            ok: false,
            same_backend: false,
            lock_held: false,
            error: None,
        });
        assert!(msg.contains("STATEMENT-mode"));
        assert!(msg.contains("next_seq"));
        assert!(msg.contains("TRANSACTION"));
        assert!(msg.contains("DB_SKIP_POOLER_CHECK"));
    }
}
