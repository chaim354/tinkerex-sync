//! One timestamp type with three textual forms, each pinned by something outside this crate:
//!   - the SQLite column text Rails writes (`2026-08-25 10:11:12.123456`, or no fraction when the
//!     microseconds are zero) — rows Rails wrote must read, and rows we write must read back in
//!     Rails, so the format is reproduced exactly rather than approximated;
//!   - the JSON form every response uses (`2026-08-25T10:11:12.123Z`, three fractional digits,
//!     truncated, UTC) — pinned by the corpus (`expires_at: '2020-01-01T00:00:00.000Z'`);
//!   - what a client may send for `expires_at`, parsed leniently the way Active Record casts it.

use chrono::{DateTime, Datelike, NaiveDate, NaiveDateTime, NaiveTime, Timelike, Utc};
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Timestamp(NaiveDateTime);

impl Timestamp {
    pub fn now() -> Self {
        Self::from_naive(Utc::now().naive_utc())
    }

    /// Microsecond precision, like a `datetime(6)` column; anything finer is dropped, never rounded.
    pub fn from_naive(t: NaiveDateTime) -> Self {
        let nanos = t.nanosecond();
        Self(t.with_nanosecond(nanos - nanos % 1_000).unwrap_or(t))
    }

    pub fn from_unix_seconds(secs: i64) -> Option<Self> {
        DateTime::<Utc>::from_timestamp(secs, 0).map(|d| Self(d.naive_utc()))
    }

    pub fn naive(&self) -> NaiveDateTime {
        self.0
    }

    pub fn unix_seconds(&self) -> i64 {
        self.0.and_utc().timestamp()
    }

    pub fn plus_seconds(&self, secs: i64) -> Self {
        Self(self.0 + chrono::Duration::seconds(secs))
    }

    pub fn minus_seconds(&self, secs: i64) -> Self {
        Self(self.0 - chrono::Duration::seconds(secs))
    }

    pub fn plus_micros(&self, micros: i64) -> Self {
        Self(self.0 + chrono::Duration::microseconds(micros))
    }

    /// Rails' `quoted_date`: `to_fs(:db)` plus `.%06d` only when `usec > 0`.
    pub fn to_sqlite_text(&self) -> String {
        let base = self.0.format("%Y-%m-%d %H:%M:%S").to_string();
        let micros = self.0.nanosecond() / 1_000;
        if micros > 0 {
            format!("{base}.{micros:06}")
        } else {
            base
        }
    }

    /// Accepts every spelling Rails or sqlx may have left in a column.
    pub fn parse_sqlite_text(s: &str) -> Option<Self> {
        const FORMATS: [&str; 4] = [
            "%Y-%m-%d %H:%M:%S%.f",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%dT%H:%M:%S%.f",
            "%Y-%m-%dT%H:%M:%S",
        ];
        let s = s.trim().trim_end_matches('Z');
        FORMATS
            .iter()
            .find_map(|f| NaiveDateTime::parse_from_str(s, f).ok())
            .map(Self::from_naive)
    }

    /// Active Support's JSON encoding: ISO 8601, UTC, exactly three fractional digits (truncated).
    pub fn to_json(&self) -> String {
        let millis = self.0.nanosecond() / 1_000_000;
        format!("{}.{millis:03}Z", self.0.format("%Y-%m-%dT%H:%M:%S"))
    }

    /// The `strftime("%Y-%m-%d %H%M")` stamp `Sync::Conflicts.conflicted_name` embeds.
    pub fn to_conflict_stamp(&self) -> String {
        self.0.format("%Y-%m-%d %H%M").to_string()
    }

    /// What a client may send (share link `expires_at`). Active Record's datetime cast accepts an
    /// ISO 8601 / RFC 3339 string with or without a zone, a plain date, or a space-separated
    /// datetime, and casts anything it cannot parse to NULL. That last behaviour is reproduced
    /// here because the corpus records what the reference server did, not what it should have.
    pub fn parse_user_input(s: &str) -> Option<Self> {
        let s = s.trim();
        if s.is_empty() {
            return None;
        }
        if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
            return Some(Self::from_naive(dt.naive_utc()));
        }
        const NAIVE: [&str; 6] = [
            "%Y-%m-%dT%H:%M:%S%.f",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%d %H:%M:%S%.f",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%dT%H:%M",
            "%Y-%m-%d %H:%M",
        ];
        if let Some(t) = NAIVE
            .iter()
            .find_map(|f| NaiveDateTime::parse_from_str(s, f).ok())
        {
            return Some(Self::from_naive(t));
        }
        if let Ok(d) = NaiveDate::parse_from_str(s, "%Y-%m-%d") {
            return Some(Self(d.and_time(NaiveTime::from_hms_opt(0, 0, 0)?)));
        }
        None
    }

    pub fn year(&self) -> i32 {
        self.0.year()
    }
}

/// Strictly increasing timestamps within one operation. Rails stamped each row it saved with its
/// own `Time.current`, and the trash listing orders by that stamp — so a cascade's children, saved
/// after their folder, list before it. Each tick is the current time or one microsecond past the
/// previous tick, whichever is later, so the order is deterministic even on a fast machine.
pub struct Clock {
    last: Timestamp,
}

impl Clock {
    pub fn new() -> Self {
        Self {
            last: Timestamp::now(),
        }
    }

    pub fn first(&self) -> Timestamp {
        self.last
    }

    pub fn tick(&mut self) -> Timestamp {
        let now = Timestamp::now();
        self.last = if now > self.last {
            now
        } else {
            self.last.plus_micros(1)
        };
        self.last
    }
}

impl Default for Clock {
    fn default() -> Self {
        Self::new()
    }
}

impl Serialize for Timestamp {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_json())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(s: &str) -> Timestamp {
        Timestamp::parse_sqlite_text(s).unwrap()
    }

    #[test]
    fn sqlite_text_matches_rails_quoted_date() {
        assert_eq!(
            at("2026-08-25 10:11:12.123456").to_sqlite_text(),
            "2026-08-25 10:11:12.123456"
        );
        assert_eq!(
            at("2026-08-25 10:11:12").to_sqlite_text(),
            "2026-08-25 10:11:12"
        );
        // Rails prints six digits even when the fraction has trailing zeros.
        assert_eq!(
            at("2026-08-25 10:11:14.5").to_sqlite_text(),
            "2026-08-25 10:11:14.500000"
        );
        // Nanoseconds beyond the sixth digit are truncated, never rounded.
        assert_eq!(
            at("2026-08-25 10:11:12.9999999").to_sqlite_text(),
            "2026-08-25 10:11:12.999999"
        );
    }

    #[test]
    fn json_form_is_active_support_iso8601_with_three_digits() {
        assert_eq!(
            at("2020-01-01 00:00:00").to_json(),
            "2020-01-01T00:00:00.000Z"
        );
        assert_eq!(
            at("2026-08-25 10:11:12.123456").to_json(),
            "2026-08-25T10:11:12.123Z"
        );
        assert_eq!(
            at("2026-08-25 10:11:12.999999").to_json(),
            "2026-08-25T10:11:12.999Z"
        );
    }

    #[test]
    fn user_input_parses_the_shapes_active_record_accepts() {
        assert_eq!(
            Timestamp::parse_user_input("2020-01-01T00:00:00Z")
                .unwrap()
                .to_json(),
            "2020-01-01T00:00:00.000Z"
        );
        assert_eq!(
            Timestamp::parse_user_input("2020-01-01T02:00:00+02:00")
                .unwrap()
                .to_json(),
            "2020-01-01T00:00:00.000Z"
        );
        assert_eq!(
            Timestamp::parse_user_input("2020-01-01").unwrap().to_json(),
            "2020-01-01T00:00:00.000Z"
        );
        assert_eq!(
            Timestamp::parse_user_input("2020-01-01 12:30:00")
                .unwrap()
                .to_json(),
            "2020-01-01T12:30:00.000Z"
        );
        assert_eq!(Timestamp::parse_user_input("never"), None);
        assert_eq!(Timestamp::parse_user_input(""), None);
    }

    #[test]
    fn clock_ticks_strictly_forward() {
        let mut c = Clock::new();
        let a = c.first();
        let b = c.tick();
        let d = c.tick();
        assert!(a < b && b < d);
    }

    #[test]
    fn ordering_and_arithmetic() {
        let t = at("2026-08-25 10:11:12");
        assert!(t.plus_seconds(300) > t);
        assert_eq!(t.plus_seconds(300).minus_seconds(300), t);
        assert_eq!(Timestamp::from_unix_seconds(t.unix_seconds()).unwrap(), t);
    }
}
