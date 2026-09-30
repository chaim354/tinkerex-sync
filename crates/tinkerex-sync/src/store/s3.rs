//! The S3 / R2 / SeaweedFS chunk store (`Sync::Storage::S3ChunkStore`): presigned SigV4 PUT and
//! GET URLs so chunk bytes move client <-> bucket and never through this process. Path-style
//! addressing, an optional custom endpoint (`CHUNK_ENDPOINT`), and `CHUNK_REGION=auto` for R2,
//! exactly as the Ruby store was configured. `exists`/`last_modified` are HEADs; `list` pages
//! `list_objects_v2` over the per-user prefix (billed per request, which is why the storage reaper
//! runs weekly); `delete` is idempotent and additionally swallows a 404, so a re-run after a
//! partial sweep cannot raise.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use aws_credential_types::Credentials;
use aws_sdk_s3::Client;
use aws_sdk_s3::config::{BehaviorVersion, Region};
use aws_sdk_s3::error::SdkError;
use aws_sdk_s3::presigning::PresigningConfig;
use aws_sdk_s3::primitives::ByteStream;

use super::{StoredObject, key_for};
use crate::time::Timestamp;

#[derive(Clone, Debug)]
pub struct S3ChunkStore {
    client: Client,
    bucket: String,
}

/// Everything `STORAGE_BACKEND=s3` reads from the environment.
#[derive(Debug, Clone)]
pub struct S3Settings {
    pub bucket: String,
    pub endpoint: Option<String>,
    pub region: String,
    pub access_key_id: String,
    pub secret_access_key: String,
}

fn http_status<E>(e: &SdkError<E>) -> Option<u16> {
    match e {
        SdkError::ServiceError(se) => Some(se.raw().status().as_u16()),
        _ => None,
    }
}

fn system_time(t: Timestamp) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(t.unix_seconds().max(0) as u64)
}

impl S3ChunkStore {
    pub fn new(settings: &S3Settings) -> Self {
        let creds = Credentials::from_keys(
            settings.access_key_id.clone(),
            settings.secret_access_key.clone(),
            None,
        );
        let mut builder = aws_sdk_s3::Config::builder()
            .behavior_version(BehaviorVersion::latest())
            .region(Region::new(settings.region.clone()))
            .credentials_provider(creds)
            .force_path_style(true);
        if let Some(endpoint) = settings
            .endpoint
            .as_deref()
            .filter(|e| !e.trim().is_empty())
        {
            builder = builder.endpoint_url(endpoint);
        }
        Self {
            client: Client::from_conf(builder.build()),
            bucket: settings.bucket.clone(),
        }
    }

    pub fn bucket(&self) -> &str {
        &self.bucket
    }

    fn presigning(expires_in: i64, now: Timestamp) -> anyhow::Result<PresigningConfig> {
        Ok(PresigningConfig::builder()
            .start_time(system_time(now))
            .expires_in(Duration::from_secs(expires_in.max(1) as u64))
            .build()?)
    }

    /// A presigned PUT for `chunks/<user>/<hash>`, signed as of `now`.
    pub async fn presign_put(
        &self,
        user_id: i64,
        hash: &str,
        expires_in: i64,
        now: Timestamp,
    ) -> anyhow::Result<String> {
        let req = self
            .client
            .put_object()
            .bucket(&self.bucket)
            .key(key_for(user_id, hash))
            .presigned(Self::presigning(expires_in, now)?)
            .await?;
        Ok(req.uri().to_string())
    }

    pub async fn presign_get(
        &self,
        user_id: i64,
        hash: &str,
        expires_in: i64,
        now: Timestamp,
    ) -> anyhow::Result<String> {
        let req = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key_for(user_id, hash))
            .presigned(Self::presigning(expires_in, now)?)
            .await?;
        Ok(req.uri().to_string())
    }

    pub async fn exists(&self, user_id: i64, hash: &str) -> anyhow::Result<bool> {
        Ok(self.last_modified(user_id, hash).await?.is_some())
    }

    pub async fn put(&self, user_id: i64, hash: &str, bytes: &[u8]) -> anyhow::Result<()> {
        self.client
            .put_object()
            .bucket(&self.bucket)
            .key(key_for(user_id, hash))
            .body(ByteStream::from(bytes.to_vec()))
            .send()
            .await?;
        Ok(())
    }

    pub async fn last_modified(
        &self,
        user_id: i64,
        hash: &str,
    ) -> anyhow::Result<Option<Timestamp>> {
        match self
            .client
            .head_object()
            .bucket(&self.bucket)
            .key(key_for(user_id, hash))
            .send()
            .await
        {
            Ok(out) => Ok(out
                .last_modified()
                .and_then(|t| Timestamp::from_unix_seconds(t.secs()))
                .or_else(|| Timestamp::from_unix_seconds(0))),
            Err(e) if http_status(&e) == Some(404) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Every object under `chunks/<user>/`, one page of 1000 keys at a time. A key with a further
    /// `/` in its suffix is not a chunk and is skipped, as the Ruby store skipped it.
    pub async fn list(&self, user_id: i64) -> anyhow::Result<Vec<StoredObject>> {
        let prefix = key_for(user_id, "");
        let mut out = Vec::new();
        let mut continuation: Option<String> = None;
        loop {
            let resp = self
                .client
                .list_objects_v2()
                .bucket(&self.bucket)
                .prefix(&prefix)
                .set_continuation_token(continuation.take())
                .send()
                .await?;
            for obj in resp.contents() {
                let Some(key) = obj.key() else { continue };
                let Some(hash) = key.strip_prefix(&prefix) else {
                    continue;
                };
                if hash.is_empty() || hash.contains('/') {
                    continue;
                }
                out.push(StoredObject {
                    hash: hash.to_string(),
                    last_modified: obj
                        .last_modified()
                        .and_then(|t| Timestamp::from_unix_seconds(t.secs())),
                });
            }
            if resp.is_truncated().unwrap_or(false) {
                continuation = resp.next_continuation_token().map(str::to_string);
                if continuation.is_none() {
                    break;
                }
            } else {
                break;
            }
        }
        Ok(out)
    }

    pub async fn delete(&self, user_id: i64, hash: &str) -> anyhow::Result<()> {
        match self
            .client
            .delete_object()
            .bucket(&self.bucket)
            .key(key_for(user_id, hash))
            .send()
            .await
        {
            Ok(_) => Ok(()),
            Err(e) if http_status(&e) == Some(404) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    //! The WIRE of a presigned URL, not a round trip through the SDK's own signer: host and
    //! path-style key, the SigV4 query parameters the bucket will check, determinism, and that
    //! the secret is actually in the signature. A real bucket round trip (MinIO/SeaweedFS) needs
    //! Docker on a runner and is a manual gate until one exists (plan §3.2).
    use super::*;
    use std::collections::HashMap;

    fn store(secret: &str) -> S3ChunkStore {
        S3ChunkStore::new(&S3Settings {
            bucket: "my-bucket".into(),
            endpoint: Some("http://127.0.0.1:9000".into()),
            region: "auto".into(),
            access_key_id: "AKIDEXAMPLE".into(),
            secret_access_key: secret.into(),
        })
    }

    fn at() -> Timestamp {
        Timestamp::from_unix_seconds(1_369_353_600).unwrap() // 2013-05-24T00:00:00Z
    }

    fn parse(url: &str) -> (String, HashMap<String, String>) {
        let (path, query) = url.split_once('?').expect("a query string");
        let params = query
            .split('&')
            .map(|kv| {
                let (k, v) = kv.split_once('=').expect("k=v");
                (k.to_string(), v.to_string())
            })
            .collect();
        (path.to_string(), params)
    }

    #[tokio::test]
    async fn a_presigned_put_is_path_style_under_the_per_user_key_with_sigv4_query_params() {
        let hash = "a".repeat(64);
        let url = store("secret-one")
            .presign_put(7, &hash, 900, at())
            .await
            .expect("presign");
        let (path, q) = parse(&url);
        assert_eq!(
            path,
            format!("http://127.0.0.1:9000/my-bucket/chunks/7/{hash}")
        );
        assert_eq!(q["X-Amz-Algorithm"], "AWS4-HMAC-SHA256");
        assert_eq!(q["X-Amz-Date"], "20130524T000000Z");
        assert_eq!(q["X-Amz-Expires"], "900");
        assert_eq!(q["X-Amz-SignedHeaders"], "host");
        assert_eq!(
            q["X-Amz-Credential"],
            "AKIDEXAMPLE%2F20130524%2Fauto%2Fs3%2Faws4_request"
        );
        let sig = &q["X-Amz-Signature"];
        assert_eq!(sig.len(), 64);
        assert!(sig.bytes().all(|b| b.is_ascii_hexdigit()));
    }

    #[tokio::test]
    async fn a_presigned_get_uses_the_hydration_ttl_and_is_deterministic_per_secret() {
        let hash = "b".repeat(64);
        let s = store("secret-one");
        let one = s.presign_get(7, &hash, 3600, at()).await.expect("presign");
        let two = s.presign_get(7, &hash, 3600, at()).await.expect("presign");
        assert_eq!(one, two, "same inputs, same URL");
        let (_, q) = parse(&one);
        assert_eq!(q["X-Amz-Expires"], "3600");
        let other = store("secret-two")
            .presign_get(7, &hash, 3600, at())
            .await
            .expect("presign");
        let (_, q2) = parse(&other);
        assert_ne!(
            q["X-Amz-Signature"], q2["X-Amz-Signature"],
            "the secret is in the signature"
        );
        assert_ne!(
            parse(&s.presign_get(8, &hash, 3600, at()).await.unwrap()).1["X-Amz-Signature"],
            q["X-Amz-Signature"],
            "another user's key signs differently"
        );
    }

    #[tokio::test]
    async fn no_endpoint_means_the_regional_aws_host() {
        let s = S3ChunkStore::new(&S3Settings {
            bucket: "examplebucket".into(),
            endpoint: None,
            region: "us-east-1".into(),
            access_key_id: "AKIDEXAMPLE".into(),
            secret_access_key: "s".into(),
        });
        let url = s.presign_get(1, &"c".repeat(64), 60, at()).await.unwrap();
        assert!(
            url.starts_with("https://s3.us-east-1.amazonaws.com/examplebucket/chunks/1/"),
            "{url}"
        );
    }
}
