//! Which versions of ONE node to keep (`Sync::RetentionPolicy`). Pruning the rest is
//! `gc::prune_version`'s job; this module only computes a keep-set, and two invariants hold in
//! every mode: the node's current version is always kept (restore-to-now must work), and so is
//! any pinned version.
//!
//! Modes: `keep_all` (the self-host default — nothing is ever pruned) and `tiered` (managed,
//! Time-Machine style thinning): under 24 h keep everything, 1–30 days one per day, 30 days to a
//! year one per ISO week, older one per month — the NEWEST of each bucket survives.

use std::collections::{HashMap, HashSet};

use chrono::TimeDelta;

use crate::config::RetentionMode;
use crate::models::Version;
use crate::time::Timestamp;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Policy {
    KeepAll,
    Tiered,
}

impl Policy {
    pub fn from_mode(mode: RetentionMode) -> Self {
        match mode {
            RetentionMode::KeepAll => Policy::KeepAll,
            RetentionMode::Tiered => Policy::Tiered,
        }
    }

    /// The `RETENTION_POLICY` spellings.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "keep_all" => Some(Policy::KeepAll),
            "tiered" => Some(Policy::Tiered),
            _ => None,
        }
    }

    /// `versions` are one node's; the answer is the set of `version_id`s to keep.
    pub fn keep_set(
        &self,
        versions: &[Version],
        current_version_id: Option<&str>,
        now: Timestamp,
    ) -> HashSet<String> {
        let mut keep = match self {
            Policy::KeepAll => versions.iter().map(|v| v.version_id.clone()).collect(),
            Policy::Tiered => tiered(versions, now),
        };
        // The invariants — never pruned, whatever the tier math said.
        if let Some(c) = current_version_id {
            keep.insert(c.to_string());
        }
        for v in versions.iter().filter(|v| v.pinned) {
            keep.insert(v.version_id.clone());
        }
        keep
    }
}

/// THE < 24h TIER'S KEY IS THE VERSION ID, NOT `created_at`. That tier's contract is "keep every
/// version", which it keeps by giving each version a bucket of its own — and `created_at` is
/// microsecond-precision, so two versions written in the same microsecond would share a bucket
/// and one would be thinned by the tier that promises to thin nothing (a recorded Ruby bug). The
/// older tiers deliberately DO collide across versions: grouping is their whole point.
#[derive(Debug, Hash, PartialEq, Eq)]
enum Bucket {
    Raw(String),
    Daily(String),
    Weekly(String),
    Monthly(String),
}

fn bucket_for(v: &Version, now: Timestamp) -> Bucket {
    let created = v.created_at.naive();
    let age = now.naive() - created;
    if age < TimeDelta::hours(24) {
        Bucket::Raw(v.version_id.clone())
    } else if age < TimeDelta::days(30) {
        Bucket::Daily(created.format("%Y-%m-%d").to_string())
    } else if age < TimeDelta::days(365) {
        Bucket::Weekly(created.format("%G-W%V").to_string()) // ISO year-week
    } else {
        Bucket::Monthly(created.format("%Y-%m").to_string())
    }
}

/// Newest per bucket. On an exact `created_at` tie the FIRST version seen wins, which is what
/// Ruby's `max_by` does; the caller's list is in id order, so the older row survives.
fn tiered(versions: &[Version], now: Timestamp) -> HashSet<String> {
    let mut newest: HashMap<Bucket, &Version> = HashMap::new();
    for v in versions {
        let key = bucket_for(v, now);
        match newest.get(&key) {
            Some(best) if best.created_at >= v.created_at => {}
            _ => {
                newest.insert(key, v);
            }
        }
    }
    newest.values().map(|v| v.version_id.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn at(secs_ago: i64) -> Timestamp {
        now().minus_seconds(secs_ago)
    }

    fn now() -> Timestamp {
        Timestamp::from_naive(
            NaiveDate::from_ymd_opt(2026, 6, 14)
                .unwrap()
                .and_hms_opt(12, 0, 0)
                .unwrap(),
        )
    }

    fn version(id: &str, secs_ago: i64, pinned: bool) -> Version {
        Version {
            id: None,
            user_id: 1,
            version_id: id.to_string(),
            node_id: "n".into(),
            manifest_id: "m".into(),
            size: 1,
            device_id: None,
            parent_version_id: None,
            pinned,
            created_at: at(secs_ago),
        }
    }

    const HOUR: i64 = 3600;
    const DAY: i64 = 86_400;

    fn ids(set: &HashSet<String>) -> Vec<&str> {
        let mut v: Vec<&str> = set.iter().map(String::as_str).collect();
        v.sort();
        v
    }

    #[test]
    fn keep_all_never_prunes() {
        let vs = [
            version("a", 60, false),
            version("b", 2 * DAY, false),
            version("c", 400 * DAY, false),
        ];
        let kept = Policy::KeepAll.keep_set(&vs, Some("a"), now());
        assert_eq!(ids(&kept), ["a", "b", "c"]);
    }

    #[test]
    fn tiered_keeps_everything_under_24h() {
        let vs = [
            version("a", 60, false),
            version("b", 3 * HOUR, false),
            version("c", 23 * HOUR, false),
        ];
        let kept = Policy::Tiered.keep_set(&vs, Some("a"), now());
        assert_eq!(ids(&kept), ["a", "b", "c"]);
    }

    #[test]
    fn tiered_keeps_all_under_24h_versions_that_share_one_created_at() {
        let vs = [
            version("a", HOUR, false),
            version("b", HOUR, false),
            version("c", HOUR, false),
        ];
        assert_eq!(
            vs[0].created_at, vs[2].created_at,
            "fixture must actually tie"
        );
        // No current version: the keep-set is the tier math alone.
        let kept = Policy::Tiered.keep_set(&vs, None, now());
        assert_eq!(ids(&kept), ["a", "b", "c"]);
    }

    #[test]
    fn tiered_thins_the_1_to_30_day_window_to_one_per_day() {
        let vs = [
            version("current", 60, false),
            version("d1", 5 * DAY, false),
            version("d2", 5 * DAY + HOUR, false),
            version("d3", 5 * DAY + 2 * HOUR, false),
        ];
        let kept = Policy::Tiered.keep_set(&vs, Some("current"), now());
        let survivors: Vec<&str> = ["d1", "d2", "d3"]
            .into_iter()
            .filter(|id| kept.contains(*id))
            .collect();
        assert_eq!(survivors, ["d1"], "the newest of the day survives");
        assert!(kept.contains("current"));
    }

    #[test]
    fn tiered_always_keeps_the_current_version_even_if_ancient() {
        let vs = [version("old", 800 * DAY, false)];
        let kept = Policy::Tiered.keep_set(&vs, Some("old"), now());
        assert!(kept.contains("old"));
    }

    #[test]
    fn tiered_always_keeps_a_pinned_version() {
        let vs = [
            version("current", 60, false),
            version("pinned", 200 * DAY, true),
            version("sibling", 200 * DAY + HOUR, false),
        ];
        let kept = Policy::Tiered.keep_set(&vs, Some("current"), now());
        assert!(kept.contains("pinned"));
    }

    #[test]
    fn tiered_buckets_older_tiers_by_week_and_month() {
        // Two versions in the same ISO week, 40 days ago -> one survives; two in the same month
        // 400 days ago -> one survives. 2026-05-05 (Tue) and 2026-05-07 (Thu) share ISO week 19.
        let vs = [
            version("w1", 40 * DAY, false),
            version("w2", 38 * DAY, false),
            version("m1", 400 * DAY, false),
            version("m2", 395 * DAY, false),
        ];
        let kept = Policy::Tiered.keep_set(&vs, None, now());
        assert_eq!(ids(&kept), ["m2", "w2"]);
    }

    #[test]
    fn parse_matches_the_env_spellings() {
        assert_eq!(Policy::parse("keep_all"), Some(Policy::KeepAll));
        assert_eq!(Policy::parse("tiered"), Some(Policy::Tiered));
        assert_eq!(Policy::parse("daily"), None);
    }
}
