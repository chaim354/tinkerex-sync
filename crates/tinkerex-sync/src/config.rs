//! Configuration from the SAME environment names the Rails host read, so the accessory's env block
//! in the maker repo's `config/deploy.yml` needs no change at cutover.

use std::path::PathBuf;

#[derive(Debug, Clone)]
pub enum DatabaseConfig {
    Sqlite { path: PathBuf },
    Postgres { url: String },
}

#[derive(Debug, Clone)]
pub enum StorageConfig {
    /// The colocated HTTP data plane: bytes under `dir`, presigned to this server's own
    /// `/v1/chunks/blob/*` routes, HMAC-signed with `secret_key_base`.
    Local {
        dir: PathBuf,
        public_url: Option<String>,
    },
    /// S3/R2/SeaweedFS over presigned SigV4 URLs; bytes never touch this process.
    S3 {
        bucket: String,
        endpoint: Option<String>,
        region: String,
        access_key_id: String,
        secret_access_key: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetentionMode {
    KeepAll,
    Tiered,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub database: DatabaseConfig,
    pub storage: StorageConfig,
    pub secret_key_base: String,
    /// `SYNC_ADMIN_TOKEN`. Blank or unset means the admin door answers 503, never a boot refusal
    /// (the Rails controller's own argument: a boot guard for one optional endpoint would take a
    /// whole deployment down over a feature it may not use).
    pub admin_token: Option<String>,
    /// `SYNC_VERIFY_FINALIZE`, default on: finalize HEADs storage for first-seen chunks.
    pub verify_finalize: bool,
    pub retention: RetentionMode,
    /// `DEVICE_IDLE_DAYS`: a DEVICE credential unused for this many days stops authenticating;
    /// `None` is off. `auth` says which credentials it covers.
    pub device_idle_days: Option<i64>,
    /// How often an open `/cable` socket re-reads its device: what cuts a socket the operator's
    /// `device revoke` (another process, so no in-process signal) or idle expiry ended, and what
    /// keeps a connected device's `last_seen_at` moving. Not an environment knob; the tests
    /// shorten it.
    pub cable_recheck: std::time::Duration,
}

/// The maker app's own default (`Device::IDLE_DAYS_DEFAULT`).
pub const DEVICE_IDLE_DAYS_DEFAULT: i64 = 90;
/// Past this many days a limit means nothing, and a larger one would overflow the date arithmetic.
const DEVICE_IDLE_DAYS_MAX: i64 = 1_000_000;
pub const CABLE_RECHECK_DEFAULT: std::time::Duration = std::time::Duration::from_secs(60);

/// The maker app's `Device.idle_limit`, rule for rule, because the two read the same variable:
/// `0` keeps every token forever; a value that is not a whole, non-negative number of days is a
/// typo and falls back to the default, never to "forever" (which would turn expiry off silently).
pub fn device_idle_days(raw: Option<&str>) -> Option<i64> {
    let days = raw
        .and_then(|v| v.trim().parse::<i64>().ok())
        .filter(|d| *d >= 0)
        .unwrap_or(DEVICE_IDLE_DAYS_DEFAULT);
    (days > 0).then_some(days.min(DEVICE_IDLE_DAYS_MAX))
}

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct ConfigError(pub String);

fn present(v: Option<String>) -> Option<String> {
    v.filter(|s| !s.trim().is_empty())
}

impl DatabaseConfig {
    pub fn from_lookup(get: &dyn Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        if let Some(url) = present(get("DATABASE_URL")) {
            if url.starts_with("postgres://") || url.starts_with("postgresql://") {
                return Ok(Self::Postgres { url });
            }
            if let Some(path) = url
                .strip_prefix("sqlite://")
                .or_else(|| url.strip_prefix("sqlite:"))
            {
                return Ok(Self::Sqlite {
                    path: PathBuf::from(path),
                });
            }
            return Err(ConfigError(format!(
                "DATABASE_URL must start with postgres:// or sqlite:, got {url:?}"
            )));
        }
        // Rails' `production:` block: `SQLITE_DATABASE`, default `storage/production.sqlite3`,
        // relative to the working directory (`/rails/host` in the image).
        let path =
            present(get("SQLITE_DATABASE")).unwrap_or_else(|| "storage/production.sqlite3".into());
        Ok(Self::Sqlite {
            path: PathBuf::from(path),
        })
    }
}

impl StorageConfig {
    pub fn from_lookup(get: &dyn Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let backend = present(get("STORAGE_BACKEND")).ok_or_else(|| {
            ConfigError(
                "STORAGE_BACKEND is not set (local or s3). There is deliberately no default: a sync \
                 server that silently fell back to a local disk would look healthy while writing every \
                 chunk somewhere a second container cannot read."
                    .into(),
            )
        })?;
        match backend.as_str() {
            "local" => Ok(Self::Local {
                dir: PathBuf::from(present(get("CHUNK_LOCAL_DIR")).unwrap_or_else(|| "tmp/chunk-store".into())),
                public_url: present(get("CHUNK_PUBLIC_URL")).map(|u| u.trim_end_matches('/').to_string()),
            }),
            "s3" => {
                let req = |k: &str| present(get(k)).ok_or_else(|| ConfigError(format!("STORAGE_BACKEND=s3 requires {k}")));
                Ok(Self::S3 {
                    bucket: req("CHUNK_BUCKET")?,
                    endpoint: present(get("CHUNK_ENDPOINT")),
                    region: present(get("CHUNK_REGION")).unwrap_or_else(|| "auto".into()),
                    access_key_id: req("CHUNK_ACCESS_KEY_ID")?,
                    secret_access_key: req("CHUNK_SECRET_ACCESS_KEY")?,
                })
            }
            "memory" => Err(ConfigError(
                "STORAGE_BACKEND=memory was the Rails test double and does not exist here; use local with \
                 CHUNK_LOCAL_DIR pointing at a scratch directory"
                    .into(),
            )),
            other => Err(ConfigError(format!("unknown STORAGE_BACKEND {other:?} (local or s3)"))),
        }
    }
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(&|k| std::env::var(k).ok())
    }

    pub fn from_lookup(get: &dyn Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let database = DatabaseConfig::from_lookup(get)?;
        let storage = StorageConfig::from_lookup(get)?;
        let secret_key_base = present(get("SECRET_KEY_BASE")).ok_or_else(|| {
            ConfigError("SECRET_KEY_BASE is not set; it signs the local blob URLs".into())
        })?;
        let verify_finalize = present(get("SYNC_VERIFY_FINALIZE"))
            .map(|v| v == "1")
            .unwrap_or(true);
        let retention = match present(get("RETENTION_POLICY")).as_deref() {
            None | Some("keep_all") => RetentionMode::KeepAll,
            Some("tiered") => RetentionMode::Tiered,
            Some(other) => return Err(ConfigError(format!("unknown RETENTION_POLICY: {other:?}"))),
        };
        Ok(Self {
            database,
            storage,
            secret_key_base,
            admin_token: present(get("SYNC_ADMIN_TOKEN")),
            verify_finalize,
            retention,
            device_idle_days: device_idle_days(get("DEVICE_IDLE_DAYS").as_deref()),
            cable_recheck: CABLE_RECHECK_DEFAULT,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn cfg(vars: &[(&str, &str)]) -> Result<Config, ConfigError> {
        let map: HashMap<String, String> = vars
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        Config::from_lookup(&|k| map.get(k).cloned())
    }

    #[test]
    fn storage_backend_has_no_default() {
        let err = cfg(&[("SECRET_KEY_BASE", "x")]).unwrap_err();
        assert!(err.0.contains("STORAGE_BACKEND"), "{err}");
    }

    #[test]
    fn local_defaults_match_the_rails_host() {
        let c = cfg(&[("STORAGE_BACKEND", "local"), ("SECRET_KEY_BASE", "x")]).unwrap();
        match c.storage {
            StorageConfig::Local { dir, public_url } => {
                assert_eq!(dir, PathBuf::from("tmp/chunk-store"));
                assert_eq!(public_url, None);
            }
            _ => panic!("expected local"),
        }
        match c.database {
            DatabaseConfig::Sqlite { path } => {
                assert_eq!(path, PathBuf::from("storage/production.sqlite3"))
            }
            _ => panic!("expected sqlite"),
        }
        assert!(c.verify_finalize);
        assert_eq!(c.retention, RetentionMode::KeepAll);
        assert_eq!(c.admin_token, None);
    }

    #[test]
    fn blank_admin_token_is_unset_and_verify_can_be_switched_off() {
        let c = cfg(&[
            ("STORAGE_BACKEND", "local"),
            ("SECRET_KEY_BASE", "x"),
            ("SYNC_ADMIN_TOKEN", "   "),
            ("SYNC_VERIFY_FINALIZE", "0"),
            ("CHUNK_PUBLIC_URL", "http://host:3001/"),
        ])
        .unwrap();
        assert_eq!(c.admin_token, None);
        assert!(!c.verify_finalize);
        match c.storage {
            StorageConfig::Local { public_url, .. } => {
                assert_eq!(public_url.as_deref(), Some("http://host:3001"))
            }
            _ => panic!(),
        }
    }

    #[test]
    fn device_idle_days_reads_the_way_the_maker_app_reads_it() {
        assert_eq!(device_idle_days(None), Some(90), "unset is the default");
        assert_eq!(device_idle_days(Some("")), Some(90), "blank is the default");
        assert_eq!(device_idle_days(Some("30")), Some(30));
        assert_eq!(device_idle_days(Some(" 7 ")), Some(7));
        assert_eq!(device_idle_days(Some("0")), None, "0 is off");
        // A typo is the default, never off: off would be the silent failure.
        assert_eq!(device_idle_days(Some("-1")), Some(90));
        assert_eq!(device_idle_days(Some("ninety")), Some(90));
        assert_eq!(device_idle_days(Some("1.5")), Some(90));
        assert_eq!(device_idle_days(Some("99999999999")), Some(1_000_000));
        let c = cfg(&[("STORAGE_BACKEND", "local"), ("SECRET_KEY_BASE", "x")]).unwrap();
        assert_eq!(c.device_idle_days, Some(90));
        let c = cfg(&[
            ("STORAGE_BACKEND", "local"),
            ("SECRET_KEY_BASE", "x"),
            ("DEVICE_IDLE_DAYS", "0"),
        ])
        .unwrap();
        assert_eq!(c.device_idle_days, None);
    }

    #[test]
    fn database_url_selects_postgres() {
        let c = cfg(&[
            ("STORAGE_BACKEND", "local"),
            ("SECRET_KEY_BASE", "x"),
            ("DATABASE_URL", "postgres://u:p@h/db"),
        ])
        .unwrap();
        assert!(matches!(c.database, DatabaseConfig::Postgres { .. }));
    }
}
