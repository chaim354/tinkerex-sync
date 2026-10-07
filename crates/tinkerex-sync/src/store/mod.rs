//! The content-addressed chunk store: presign PUT (upload missing chunks) and GET (hydration) so
//! bytes move client <-> storage directly. Two backends, chosen by `STORAGE_BACKEND`:
//! `local` (this server's own signed blob tier, the one sanctioned place bytes touch the process)
//! and `s3`. An enum rather than a trait object: every caller needs the async methods and only
//! the adapter knows which situation it is in.

pub mod local;
pub mod s3;

use crate::config::StorageConfig;
use crate::time::Timestamp;

pub use local::LocalChunkStore;
pub use s3::{S3ChunkStore, S3Settings};

/// Per-user prefix isolates tenants and bounds every presigned URL's scope.
pub fn key_for(user_id: i64, hash: &str) -> String {
    format!("chunks/{user_id}/{hash}")
}

/// Presign TTLs (seconds) the Rails stores used: 15 minutes to upload, an hour to hydrate.
pub const PUT_EXPIRES_IN: i64 = 900;
pub const GET_EXPIRES_IN: i64 = 3600;

#[derive(Debug, Clone)]
pub struct StoredObject {
    pub hash: String,
    pub last_modified: Option<Timestamp>,
}

#[derive(Clone)]
pub enum ChunkStore {
    Local(LocalChunkStore),
    S3(S3ChunkStore),
}

impl ChunkStore {
    pub fn from_config(cfg: &StorageConfig, secret_key_base: &str) -> anyhow::Result<Self> {
        match cfg {
            StorageConfig::Local { dir, public_url } => Ok(ChunkStore::Local(
                LocalChunkStore::new(dir.clone(), public_url.clone(), secret_key_base)?,
            )),
            StorageConfig::S3 {
                bucket,
                endpoint,
                region,
                access_key_id,
                secret_access_key,
            } => Ok(ChunkStore::S3(S3ChunkStore::new(&S3Settings {
                bucket: bucket.clone(),
                endpoint: endpoint.clone(),
                region: region.clone(),
                access_key_id: access_key_id.clone(),
                secret_access_key: secret_access_key.clone(),
            }))),
        }
    }

    pub fn local(&self) -> Option<&LocalChunkStore> {
        match self {
            ChunkStore::Local(l) => Some(l),
            ChunkStore::S3(_) => None,
        }
    }

    pub fn backend_name(&self) -> &'static str {
        match self {
            ChunkStore::Local(_) => "local",
            ChunkStore::S3(_) => "s3",
        }
    }

    /// `base_url` is what the client reached us at (scheme + host); only the local store uses it,
    /// and only when no `CHUNK_PUBLIC_URL` is configured.
    pub async fn presign_put(
        &self,
        base_url: &str,
        user_id: i64,
        hash: &str,
        now: Timestamp,
    ) -> anyhow::Result<String> {
        match self {
            ChunkStore::Local(l) => {
                Ok(l.blob_url(base_url, user_id, hash, now.unix_seconds() + PUT_EXPIRES_IN))
            }
            ChunkStore::S3(s) => s.presign_put(user_id, hash, PUT_EXPIRES_IN, now).await,
        }
    }

    pub async fn presign_get(
        &self,
        base_url: &str,
        user_id: i64,
        hash: &str,
        now: Timestamp,
    ) -> anyhow::Result<String> {
        match self {
            ChunkStore::Local(l) => {
                Ok(l.blob_url(base_url, user_id, hash, now.unix_seconds() + GET_EXPIRES_IN))
            }
            ChunkStore::S3(s) => s.presign_get(user_id, hash, GET_EXPIRES_IN, now).await,
        }
    }

    pub async fn exists(&self, user_id: i64, hash: &str) -> anyhow::Result<bool> {
        match self {
            ChunkStore::Local(l) => l.exists(user_id, hash).await,
            ChunkStore::S3(s) => s.exists(user_id, hash).await,
        }
    }

    /// Server-side write of one chunk — the exception for server-generated content, and the
    /// blob tier's own PUT. Content-addressed, so idempotent.
    pub async fn put(&self, user_id: i64, hash: &str, bytes: &[u8]) -> anyhow::Result<()> {
        match self {
            ChunkStore::Local(l) => l.write(user_id, hash, bytes).await,
            ChunkStore::S3(s) => s.put(user_id, hash, bytes).await,
        }
    }

    pub async fn last_modified(
        &self,
        user_id: i64,
        hash: &str,
    ) -> anyhow::Result<Option<Timestamp>> {
        match self {
            ChunkStore::Local(l) => l.last_modified(user_id, hash).await,
            ChunkStore::S3(s) => s.last_modified(user_id, hash).await,
        }
    }

    pub async fn list(&self, user_id: i64) -> anyhow::Result<Vec<StoredObject>> {
        match self {
            ChunkStore::Local(l) => l.list(user_id).await,
            ChunkStore::S3(s) => s.list(user_id).await,
        }
    }

    /// Idempotent: deleting an absent key is a no-op, because the GC sweep calls this after the
    /// chunk row is gone and a re-run after a partial sweep must not raise.
    pub async fn delete(&self, user_id: i64, hash: &str) -> anyhow::Result<()> {
        match self {
            ChunkStore::Local(l) => l.delete(user_id, hash).await,
            ChunkStore::S3(s) => s.delete(user_id, hash).await,
        }
    }
}
