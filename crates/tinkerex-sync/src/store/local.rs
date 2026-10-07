//! A real HTTP data plane on the local filesystem: the self-hosted analogue of S3 with no external
//! object store. It presigns `http(s)://<host>/v1/chunks/blob/<user>/<hash>?exp&sig` URLs the
//! client PUTs and GETs; the path is HMAC-signed with `SECRET_KEY_BASE` over
//! `"<user_id>\n<hash>\n<exp>"`, exactly as `Sync::Storage::LocalChunkStore` signed it, so URLs
//! minted by the Rails host before cutover still verify here.

use std::path::{Path, PathBuf};

use hmac::{Hmac, KeyInit as _, Mac as _};
use sha2::Sha256;
use subtle::ConstantTimeEq as _;

use super::StoredObject;
use crate::time::Timestamp;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone)]
pub struct LocalChunkStore {
    dir: PathBuf,
    public_url: Option<String>,
    signing_key: Vec<u8>,
}

impl std::fmt::Debug for LocalChunkStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocalChunkStore")
            .field("dir", &self.dir)
            .field("public_url", &self.public_url)
            .finish()
    }
}

/// The on-disk hash constraint the Rails store applied: hex, 8..128 chars — content-addressed, so
/// it can never carry a path separator, but constrained to the store root regardless.
fn valid_hash(hash: &str) -> bool {
    (8..=128).contains(&hash.len()) && hash.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

impl LocalChunkStore {
    pub fn new(
        dir: PathBuf,
        public_url: Option<String>,
        secret_key_base: &str,
    ) -> anyhow::Result<Self> {
        std::fs::create_dir_all(&dir)?;
        Ok(Self {
            dir,
            public_url,
            signing_key: secret_key_base.as_bytes().to_vec(),
        })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn path_for(&self, user_id: i64, hash: &str) -> anyhow::Result<PathBuf> {
        if !valid_hash(hash) {
            anyhow::bail!("bad hash");
        }
        Ok(self.dir.join("chunks").join(user_id.to_string()).join(hash))
    }

    pub fn sign(&self, user_id: i64, hash: &str, exp: i64) -> String {
        let mut mac =
            HmacSha256::new_from_slice(&self.signing_key).expect("HMAC accepts any key length");
        mac.update(format!("{user_id}\n{hash}\n{exp}").as_bytes());
        hex::encode(mac.finalize().into_bytes())
    }

    /// Constant-time compare; rejects an expired URL first.
    pub fn verify(&self, user_id: i64, hash: &str, exp: i64, sig: &str, now: Timestamp) -> bool {
        if exp < now.unix_seconds() {
            return false;
        }
        let expected = self.sign(user_id, hash, exp);
        expected.as_bytes().ct_eq(sig.as_bytes()).into()
    }

    pub fn blob_url(&self, request_base_url: &str, user_id: i64, hash: &str, exp: i64) -> String {
        let base = self
            .public_url
            .as_deref()
            .unwrap_or(request_base_url)
            .trim_end_matches('/');
        let sig = self.sign(user_id, hash, exp);
        format!("{base}/v1/chunks/blob/{user_id}/{hash}?exp={exp}&sig={sig}")
    }

    pub async fn exists(&self, user_id: i64, hash: &str) -> anyhow::Result<bool> {
        Ok(tokio::fs::metadata(self.path_for(user_id, hash)?)
            .await
            .map(|m| m.is_file())
            .unwrap_or(false))
    }

    pub async fn read(&self, user_id: i64, hash: &str) -> anyhow::Result<Option<Vec<u8>>> {
        match tokio::fs::read(self.path_for(user_id, hash)?).await {
            Ok(bytes) => Ok(Some(bytes)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Atomic: write a temp file then rename, so a concurrent reader never sees a partial blob
    /// (two devices may PUT the same content-addressed chunk at once; last writer is identical).
    pub async fn write(&self, user_id: i64, hash: &str, bytes: &[u8]) -> anyhow::Result<()> {
        let path = self.path_for(user_id, hash)?;
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        let tmp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4().simple()));
        tokio::fs::write(&tmp, bytes).await?;
        tokio::fs::rename(&tmp, &path).await?;
        Ok(())
    }

    pub async fn last_modified(
        &self,
        user_id: i64,
        hash: &str,
    ) -> anyhow::Result<Option<Timestamp>> {
        match tokio::fs::metadata(self.path_for(user_id, hash)?).await {
            Ok(m) => Ok(Some(mtime_of(&m)?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    pub async fn list(&self, user_id: i64) -> anyhow::Result<Vec<StoredObject>> {
        let base = self.dir.join("chunks").join(user_id.to_string());
        let mut out = Vec::new();
        let mut entries = match tokio::fs::read_dir(&base).await {
            Ok(e) => e,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
            Err(e) => return Err(e.into()),
        };
        while let Some(entry) = entries.next_entry().await? {
            let meta = entry.metadata().await?;
            if !meta.is_file() {
                continue;
            }
            let Some(name) = entry.file_name().to_str().map(str::to_string) else {
                continue;
            };
            if !valid_hash(&name) {
                continue; // a leftover temp file, never an object
            }
            out.push(StoredObject {
                hash: name,
                last_modified: Some(mtime_of(&meta)?),
            });
        }
        out.sort_by(|a, b| a.hash.cmp(&b.hash));
        Ok(out)
    }

    pub async fn delete(&self, user_id: i64, hash: &str) -> anyhow::Result<()> {
        match tokio::fs::remove_file(self.path_for(user_id, hash)?).await {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// Test helper: backdate an object's storage age (deterministic grace-window tests).
    pub fn set_mtime(&self, user_id: i64, hash: &str, at: Timestamp) -> anyhow::Result<()> {
        let path = self.path_for(user_id, hash)?;
        let t = std::fs::FileTimes::new().set_modified(
            std::time::UNIX_EPOCH + std::time::Duration::from_secs(at.unix_seconds().max(0) as u64),
        );
        std::fs::File::options()
            .write(true)
            .open(path)?
            .set_times(t)?;
        Ok(())
    }
}

fn mtime_of(m: &std::fs::Metadata) -> anyhow::Result<Timestamp> {
    let secs = m
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64;
    Timestamp::from_unix_seconds(secs).ok_or_else(|| anyhow::anyhow!("mtime out of range"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, LocalChunkStore) {
        let dir = tempfile::tempdir().unwrap();
        let s = LocalChunkStore::new(dir.path().join("store"), None, "test-secret").unwrap();
        (dir, s)
    }

    #[test]
    fn signature_matches_the_ruby_formula() {
        // Known answer: OpenSSL::HMAC.hexdigest("SHA256", "test-secret", "7\nabcdef12\n1700000000")
        let (_d, s) = store();
        assert_eq!(
            s.sign(7, "abcdef12", 1_700_000_000),
            "624d6aee4a497476e3f762796859e14eed547333bc6bb2afd3cc9399caea0b97"
        );
        let now = Timestamp::from_unix_seconds(1_699_999_000).unwrap();
        let sig = s.sign(7, "abcdef12", 1_700_000_000);
        assert!(s.verify(7, "abcdef12", 1_700_000_000, &sig, now));
        assert!(
            !s.verify(8, "abcdef12", 1_700_000_000, &sig, now),
            "another user's key"
        );
        assert!(
            !s.verify(7, "abcdef12", 1_700_000_001, &sig, now),
            "a changed expiry"
        );
        assert!(
            !s.verify(
                7,
                "abcdef12",
                1_700_000_000,
                &sig,
                Timestamp::from_unix_seconds(1_700_000_001).unwrap()
            ),
            "expired"
        );
    }

    #[test]
    fn urls_use_the_public_url_when_configured_and_the_request_host_otherwise() {
        let (_d, s) = store();
        let url = s.blob_url("http://127.0.0.1:3003", 7, "abcdef12", 1_700_000_000);
        assert!(
            url.starts_with("http://127.0.0.1:3003/v1/chunks/blob/7/abcdef12?exp=1700000000&sig="),
            "{url}"
        );
        let dir = tempfile::tempdir().unwrap();
        let p = LocalChunkStore::new(
            dir.path().to_path_buf(),
            Some("http://sync.example/".into()),
            "k",
        )
        .unwrap();
        assert!(
            p.blob_url("http://ignored", 7, "abcdef12", 1)
                .starts_with("http://sync.example/v1/chunks/blob/7/abcdef12?exp=1&sig=")
        );
    }

    #[tokio::test]
    async fn bytes_round_trip_and_the_store_refuses_a_bad_hash() {
        let (_d, s) = store();
        let hash = "a".repeat(64);
        assert!(!s.exists(1, &hash).await.unwrap());
        s.write(1, &hash, b"hello \xff bytes").await.unwrap();
        assert!(s.exists(1, &hash).await.unwrap());
        assert_eq!(
            s.read(1, &hash).await.unwrap().unwrap(),
            b"hello \xff bytes"
        );
        assert_eq!(s.list(1).await.unwrap().len(), 1);
        assert!(s.last_modified(1, &hash).await.unwrap().is_some());
        s.delete(1, &hash).await.unwrap();
        s.delete(1, &hash).await.unwrap(); // idempotent
        assert!(s.read(1, &hash).await.unwrap().is_none());
        assert!(s.path_for(1, "../escape").is_err());
        assert!(
            s.path_for(1, "ABCDEF12").is_err(),
            "uppercase is not a hash here"
        );
    }
}
