//! The s3 store against a REAL bucket (plan §3.2's manual gate, made runnable): SeaweedFS or
//! MinIO at `TEST_S3_ENDPOINT`, credentials in `TEST_S3_ACCESS_KEY_ID`/`TEST_S3_SECRET_ACCESS_KEY`,
//! bucket `TEST_S3_BUCKET` (created if absent). Without the endpoint the test PRINTS that it did
//! not run rather than passing silently. Three layers: the store's own verbs, a presigned PUT and
//! GET driven the way a device drives them, and a whole commit through the HTTP server whose
//! finalize verifies the bytes by HEAD against the bucket.

mod support;

use serde_json::{Value, json};
use support::{TestServer, hex};
use tinkerex_sync::ids::new_uuid;
use tinkerex_sync::services::reapers;
use tinkerex_sync::store::{S3ChunkStore, S3Settings};
use tinkerex_sync::time::Timestamp;

struct Env {
    endpoint: String,
    bucket: String,
    key: String,
    secret: String,
}

fn env() -> Option<Env> {
    let endpoint = std::env::var("TEST_S3_ENDPOINT")
        .ok()
        .filter(|e| !e.is_empty())?;
    Some(Env {
        endpoint,
        bucket: std::env::var("TEST_S3_BUCKET").unwrap_or_else(|_| "tinkerex-test".into()),
        key: std::env::var("TEST_S3_ACCESS_KEY_ID").unwrap_or_default(),
        secret: std::env::var("TEST_S3_SECRET_ACCESS_KEY").unwrap_or_default(),
    })
}

async fn ensure_bucket(e: &Env) {
    use aws_sdk_s3::config::{BehaviorVersion, Region};
    let creds = aws_credential_types::Credentials::from_keys(e.key.clone(), e.secret.clone(), None);
    let cfg = aws_sdk_s3::Config::builder()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new("us-east-1"))
        .credentials_provider(creds)
        .force_path_style(true)
        .endpoint_url(&e.endpoint)
        .build();
    let client = aws_sdk_s3::Client::from_conf(cfg);
    if let Err(err) = client.create_bucket().bucket(&e.bucket).send().await {
        let text = format!("{err:?}");
        assert!(
            text.contains("BucketAlreadyOwnedByYou") || text.contains("BucketAlreadyExists"),
            "create_bucket: {text}"
        );
    }
}

fn settings(e: &Env) -> S3Settings {
    S3Settings {
        bucket: e.bucket.clone(),
        endpoint: Some(e.endpoint.clone()),
        region: "us-east-1".into(),
        access_key_id: e.key.clone(),
        secret_access_key: e.secret.clone(),
    }
}

#[tokio::test]
async fn the_store_round_trips_against_a_real_bucket() {
    let Some(e) = env() else {
        eprintln!("s3 round trip NOT RUN: TEST_S3_ENDPOINT is unset");
        return;
    };
    ensure_bucket(&e).await;
    let store = S3ChunkStore::new(&settings(&e));
    let (user, other) = (7001, 7002);
    let h = hex();
    assert!(!store.exists(user, &h).await.unwrap());
    assert_eq!(store.last_modified(user, &h).await.unwrap(), None);

    store.put(user, &h, b"bytes in a bucket").await.unwrap();
    assert!(store.exists(user, &h).await.unwrap());
    assert!(store.last_modified(user, &h).await.unwrap().is_some());
    let listed = store.list(user).await.unwrap();
    assert!(
        listed.iter().any(|o| o.hash == h),
        "list sees the object: {listed:?}"
    );
    assert!(
        !store.list(other).await.unwrap().iter().any(|o| o.hash == h),
        "another user's prefix does not"
    );

    store.delete(user, &h).await.unwrap();
    assert!(!store.exists(user, &h).await.unwrap());
    store
        .delete(user, &h)
        .await
        .expect("deleting an absent key is a no-op");
    eprintln!("s3 round trip RAN: store verbs against {}", e.endpoint);
}

#[tokio::test]
async fn presigned_put_and_get_move_bytes_the_way_a_device_does() {
    let Some(e) = env() else {
        eprintln!("s3 presign round trip NOT RUN: TEST_S3_ENDPOINT is unset");
        return;
    };
    ensure_bucket(&e).await;
    let store = S3ChunkStore::new(&settings(&e));
    let client = reqwest::Client::new();
    let (user, h) = (7003, hex());
    let now = Timestamp::now();

    let put = store.presign_put(user, &h, 900, now).await.unwrap();
    let resp = client
        .put(&put)
        .body(b"presigned bytes".to_vec())
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200, "{}", resp.text().await.unwrap());
    assert!(
        store.exists(user, &h).await.unwrap(),
        "the PUT landed under the per-user key"
    );

    let get = store.presign_get(user, &h, 3600, now).await.unwrap();
    let resp = client.get(&get).send().await.unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.bytes().await.unwrap().as_ref(), b"presigned bytes");

    let stale = store
        .presign_get(user, &h, 900, now.minus_seconds(7200))
        .await
        .unwrap();
    let resp = client.get(&stale).send().await.unwrap();
    assert_eq!(
        resp.status(),
        403,
        "an expired presign is refused by the bucket"
    );

    store.delete(user, &h).await.unwrap();
    eprintln!("s3 presign round trip RAN");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_through_the_server_uploads_to_the_bucket_and_finalize_verifies_it_there() {
    let Some(e) = env() else {
        eprintln!("s3 server round trip NOT RUN: TEST_S3_ENDPOINT is unset");
        return;
    };
    ensure_bucket(&e).await;
    let server = TestServer::start_s3(&e.endpoint, &e.bucket, &e.key, &e.secret).await;
    let d = server
        .issue_device("s3-commit@test.example", "device")
        .await;
    let client = server.http();
    let bytes = b"committed through the server into the bucket";
    let h = tinkerex_sync::ids::sha256_hex(bytes);
    let (commit_id, node_id) = (new_uuid(), new_uuid());

    let begun: Value = client
        .post(format!("{}/v1/commit", server.base_url))
        .bearer_auth(&d.device_token)
        .json(&json!({
            "commit_id": commit_id, "node_id": node_id, "parent_node_id": null,
            "name": "bucket.bin", "base_version_id": null, "size": bytes.len(),
            "manifest": [{ "hash": h, "offset": 0, "length": bytes.len() }]
        }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let put_url = begun["put_urls"][&h]
        .as_str()
        .expect("a presigned PUT for the missing chunk");
    assert!(
        put_url.starts_with(&e.endpoint),
        "the URL points at the bucket, not at this server: {put_url}"
    );

    // Finalize before the upload: verify HEADs the bucket and refuses.
    let refused = client
        .post(format!(
            "{}/v1/commit/{commit_id}/finalize",
            server.base_url
        ))
        .bearer_auth(&d.device_token)
        .send()
        .await
        .unwrap();
    assert_eq!(refused.status(), 422);
    assert_eq!(
        refused.json::<Value>().await.unwrap()["missing"],
        json!([h])
    );

    let resp = client
        .put(put_url)
        .body(bytes.to_vec())
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let done = client
        .post(format!(
            "{}/v1/commit/{commit_id}/finalize",
            server.base_url
        ))
        .bearer_auth(&d.device_token)
        .send()
        .await
        .unwrap();
    assert_eq!(done.status(), 200, "{}", done.text().await.unwrap());

    let urls: Value = client
        .post(format!("{}/v1/chunks/download", server.base_url))
        .bearer_auth(&d.device_token)
        .json(&json!({ "hashes": [h] }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let get_url = urls["urls"][&h].as_str().expect("a presigned GET");
    let fetched = client.get(get_url).send().await.unwrap();
    assert_eq!(fetched.status(), 200);
    assert_eq!(fetched.bytes().await.unwrap().as_ref(), bytes);

    // The storage reaper lists the bucket and spares a committed chunk.
    let reaped = reapers::reap_storage(
        &server.db,
        server.store(),
        d.user_id,
        0,
        true,
        Timestamp::now(),
    )
    .await
    .unwrap();
    assert!(
        !reaped.contains(&h),
        "a committed chunk is never reaped: {reaped:?}"
    );
    server.store().delete(d.user_id, &h).await.unwrap();
    eprintln!("s3 server round trip RAN");
}
