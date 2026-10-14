//! `serve --scheduler`: the three maintenance jobs the Ruby host DEFINED and never scheduled
//! (its `config/` had no `recurring.yml`; nothing enqueued `Sync::RetentionJob`,
//! `Sync::ChunkReaperJob` or `Sync::PendingCommitReaperJob` — plan §0). Off by default, and
//! turned on only after the dry-runs the cutover plan (§7.4) calls for: enabling the reapers
//! deletes bytes the Ruby deployment never deleted.
//!
//! Cadence, on the wall clock so a restart does not shift it: reap-pending hourly at :30,
//! retention nightly at 03:15 UTC, reap-storage (the billed LIST) Sundays at 04:15 UTC. One job
//! at a time in this process (the Ruby `limits_concurrency ... on_conflict: :block` posture —
//! a late run beats a dropped one), and on Postgres a transaction-scoped advisory lock so two
//! replicas cannot run the same tick.

use std::sync::Arc;

use chrono::{Datelike, NaiveDateTime, TimeDelta, Timelike, Weekday};

use crate::db::{Db, Dialect, Query, Tx};
use crate::http::State;
use crate::models::User;
use crate::services::gc;
use crate::services::reapers::{self, PENDING_COMMIT_TTL_SECS};
use crate::services::retention::Policy;
use crate::time::Timestamp;

pub const ADVISORY_KEY: i64 = 424243;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Job {
    ReapPending,
    Retention,
    ReapStorage,
}

impl Job {
    pub const ALL: [Job; 3] = [Job::ReapPending, Job::Retention, Job::ReapStorage];

    pub fn name(self) -> &'static str {
        match self {
            Job::ReapPending => "reap-pending",
            Job::Retention => "retention",
            Job::ReapStorage => "reap-storage",
        }
    }

    /// The first instant strictly after `now` this job runs.
    pub fn next_run(self, now: NaiveDateTime) -> NaiveDateTime {
        match self {
            Job::ReapPending => {
                let base = now
                    .date()
                    .and_hms_opt(now.hour(), 30, 0)
                    .expect("valid time");
                if base > now {
                    base
                } else {
                    base + TimeDelta::hours(1)
                }
            }
            Job::Retention => {
                let base = now.date().and_hms_opt(3, 15, 0).expect("valid time");
                if base > now {
                    base
                } else {
                    base + TimeDelta::days(1)
                }
            }
            Job::ReapStorage => {
                let mut day = now.date();
                loop {
                    let candidate = day.and_hms_opt(4, 15, 0).expect("valid time");
                    if day.weekday() == Weekday::Sun && candidate > now {
                        return candidate;
                    }
                    day = day.succ_opt().expect("a next day");
                }
            }
        }
    }
}

/// Spawn one loop per job; returns immediately.
pub fn spawn(state: State) {
    let gate = Arc::new(tokio::sync::Mutex::new(()));
    for job in Job::ALL {
        let state = state.clone();
        let gate = gate.clone();
        tokio::spawn(async move {
            loop {
                let now = Timestamp::now().naive();
                let at = job.next_run(now);
                let wait = (at - now).to_std().unwrap_or_default();
                tracing::info!(job = job.name(), at = %at, "scheduler: next run");
                tokio::time::sleep(wait).await;
                let _one_at_a_time = gate.lock().await;
                run_job(&state, job).await;
            }
        });
    }
}

enum Claim {
    NotNeeded,
    Held(#[allow(dead_code)] Tx),
    Busy,
}

/// On Postgres, a transaction-scoped advisory lock held for the job's duration; the transaction
/// is dropped (and the lock released) when the claim is.
async fn claim(db: &Db) -> anyhow::Result<Claim> {
    if !matches!(db.dialect(), Dialect::Postgres) {
        return Ok(Claim::NotNeeded);
    }
    let mut tx = db.begin().await?;
    let got = tx
        .fetch_one(&Query::new(format!(
            "SELECT pg_try_advisory_xact_lock({ADVISORY_KEY}) AS ok"
        )))
        .await?
        .bool("ok")?;
    Ok(if got { Claim::Held(tx) } else { Claim::Busy })
}

/// One tick of one job, over every user, with per-user failures isolated.
pub async fn run_job(state: &State, job: Job) {
    let _claim = match claim(&state.db).await {
        Ok(Claim::Busy) => {
            tracing::info!(
                job = job.name(),
                "scheduler: another instance holds the lock; skipping"
            );
            return;
        }
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(job = job.name(), error = %e, "scheduler: could not take the lock; skipping");
            return;
        }
    };
    let now = Timestamp::now();
    let started = std::time::Instant::now();
    let outcome: anyhow::Result<String> = async {
        match job {
            Job::ReapPending => {
                let n = reapers::reap_pending_all(
                    &state.db,
                    &state.store,
                    PENDING_COMMIT_TTL_SECS,
                    false,
                    now,
                )
                .await?;
                Ok(format!("reaped {n} orphan chunk(s)"))
            }
            Job::ReapStorage => {
                let n = reapers::reap_storage_all(
                    &state.db,
                    &state.store,
                    PENDING_COMMIT_TTL_SECS,
                    false,
                    now,
                )
                .await?;
                Ok(format!("reaped {n} orphan chunk(s)"))
            }
            Job::Retention => {
                let policy = Policy::from_mode(state.config.retention);
                let mut db = state.db.clone();
                let mut pruned = 0u64;
                for user_id in User::all_ids(&mut db).await? {
                    match gc::apply_retention(
                        &state.db,
                        &state.store,
                        user_id,
                        policy,
                        gc::DEFAULT_GRACE_SECS,
                        false,
                        now,
                    )
                    .await
                    {
                        Ok(n) => pruned += n,
                        Err(e) => tracing::error!(user_id, error = %e, "retention failed for user"),
                    }
                }
                Ok(format!("pruned {pruned} version(s) ({policy:?})"))
            }
        }
    }
    .await;
    match outcome {
        Ok(summary) => {
            tracing::info!(job = job.name(), elapsed_ms = started.elapsed().as_millis() as u64, %summary, "scheduler: job done")
        }
        Err(e) => tracing::error!(job = job.name(), error = %e, "scheduler: job failed"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn at(y: i32, m: u32, d: u32, h: u32, min: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(y, m, d)
            .unwrap()
            .and_hms_opt(h, min, 0)
            .unwrap()
    }

    #[test]
    fn reap_pending_runs_at_the_next_half_hour() {
        assert_eq!(
            Job::ReapPending.next_run(at(2026, 9, 30, 10, 12)),
            at(2026, 9, 30, 10, 30)
        );
        assert_eq!(
            Job::ReapPending.next_run(at(2026, 9, 30, 10, 30)),
            at(2026, 9, 30, 11, 30)
        );
        assert_eq!(
            Job::ReapPending.next_run(at(2026, 9, 30, 23, 45)),
            at(2026, 10, 1, 0, 30)
        );
    }

    #[test]
    fn retention_runs_nightly_at_0315() {
        assert_eq!(
            Job::Retention.next_run(at(2026, 9, 30, 1, 0)),
            at(2026, 9, 30, 3, 15)
        );
        assert_eq!(
            Job::Retention.next_run(at(2026, 9, 30, 3, 15)),
            at(2026, 10, 1, 3, 15)
        );
    }

    #[test]
    fn reap_storage_runs_sundays_at_0415() {
        // 2026-09-30 is a Wednesday; the next Sunday is 2026-10-04.
        assert_eq!(
            Job::ReapStorage.next_run(at(2026, 9, 30, 12, 0)),
            at(2026, 10, 4, 4, 15)
        );
        assert_eq!(
            Job::ReapStorage.next_run(at(2026, 10, 4, 4, 15)),
            at(2026, 10, 11, 4, 15)
        );
        assert_eq!(
            Job::ReapStorage.next_run(at(2026, 10, 4, 4, 0)),
            at(2026, 10, 4, 4, 15)
        );
    }
}
