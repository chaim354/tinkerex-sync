//! The per-route body limits (plan §3.8), the lock TTL, and the statement budget of the read
//! services — the properties no corpus file can carry (a 64 MiB body, a clock, a query count).

mod support;

use serde_json::{Value, json};
use support::{TestServer, c, hex};
use tinkerex_sync::http::{BLOB_MAX_BYTES, COMMIT_BODY_LIMIT, JSON_BODY_LIMIT};
use tinkerex_sync::ids::new_uuid;
use tinkerex_sync::services::commit::{self, BeginParams};
use tinkerex_sync::services::locks::{self, TTL_SECONDS};
use tinkerex_sync::time::Timestamp;

async fn put_url(server: &TestServer, user_id: i64, device_id: i64, hash: &str) -> String {
    let manifest = vec![support::chunk(hash, 5)];
    let begun = commit::begin(
        &server.db,
        server.store(),
        &server.base_url,
        user_id,
        BeginParams {
            commit_id: Some(new_uuid()),
            node_id: Some(new_uuid()),
            parent_node_id: None,
            name: Some("big.bin".into()),
            base_version_id: None,
            size: 5,
            mode: None,
            mtime: None,
            manifest: &manifest,
            device_id: Some(device_id),
        },
        Timestamp::now(),
    )
    .await
    .expect("begin");
    begun.put_urls[hash].clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_blob_put_over_64_mib_is_refused_and_a_small_one_lands() {
    let server = TestServer::start().await;
    let d = server
        .issue_device("limits-blob@test.example", "device")
        .await;
    let hash = hex();
    let url = put_url(&server, d.user_id, d.device_id, &hash).await;
    let client = server.http();

    let resp = client
        .put(&url)
        .body(vec![0u8; BLOB_MAX_BYTES + 1])
        .send()
        .await
        .expect("oversize put");
    assert_eq!(resp.status(), 413);
    assert_eq!(resp.text().await.unwrap(), "chunk too large");
    assert!(
        !server.store().exists(d.user_id, &hash).await.unwrap(),
        "nothing was stored"
    );

    let resp = client.put(&url).body(vec![7u8; 1024]).send().await.unwrap();
    assert_eq!(resp.status(), 200);
    assert!(server.store().exists(d.user_id, &hash).await.unwrap());
}

fn manifest_json(entries: usize) -> Value {
    let manifest: Vec<Value> = (0..entries)
        .map(|i| json!({ "hash": format!("{:064x}", i + 1), "offset": i * 5, "length": 5 }))
        .collect();
    json!({
        "commit_id": new_uuid(), "node_id": new_uuid(), "parent_node_id": null,
        "name": "many.bin", "base_version_id": null, "size": entries * 5, "manifest": manifest
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_body_may_exceed_the_json_limit_up_to_its_own_16_mib() {
    let server = TestServer::start().await;
    let d = server
        .issue_device("limits-commit@test.example", "device")
        .await;
    let client = server.http();
    let url = format!("{}/v1/commit", server.base_url);

    let body = serde_json::to_vec(&manifest_json(20_000)).unwrap();
    assert!(
        body.len() > JSON_BODY_LIMIT && body.len() < COMMIT_BODY_LIMIT,
        "{}",
        body.len()
    );
    let resp = client
        .post(&url)
        .bearer_auth(&d.device_token)
        .header("content-type", "application/json")
        .body(body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200, "{}", resp.text().await.unwrap());

    let body = serde_json::to_vec(&manifest_json(170_000)).unwrap();
    assert!(body.len() > COMMIT_BODY_LIMIT, "{}", body.len());
    let resp = client
        .post(&url)
        .bearer_auth(&d.device_token)
        .header("content-type", "application/json")
        .body(body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 413);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_ordinary_json_route_refuses_a_body_over_1_mib() {
    let server = TestServer::start().await;
    let d = server
        .issue_device("limits-json@test.example", "device")
        .await;
    let hashes: Vec<String> = (0..20_000).map(|i| format!("{i:064x}")).collect();
    let body = serde_json::to_vec(&json!({ "hashes": hashes })).unwrap();
    assert!(body.len() > JSON_BODY_LIMIT);
    let resp = server
        .http()
        .post(format!("{}/v1/chunks/download", server.base_url))
        .bearer_auth(&d.device_token)
        .header("content-type", "application/json")
        .body(body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 413);
}

#[tokio::test]
async fn a_lock_expires_after_its_ttl_and_only_then_can_another_device_take_it() {
    let server = TestServer::start().await;
    let a = server.issue_device("locks-a@test.example", "a").await;
    let b = tinkerex_sync::services::provisioning::register_device(
        &server.db,
        a.user_id,
        "b",
        Timestamp::now(),
    )
    .await
    .expect("a second device of the same user");
    let node = new_uuid();
    let now = support::frozen_now();
    server
        .commit_file(
            a.user_id,
            a.device_id,
            &node,
            "locked.txt",
            None,
            &[c(&hex())],
            now,
        )
        .await;

    let first = locks::acquire(&server.db, a.user_id, &node, a.device_id, now)
        .await
        .unwrap();
    assert!(first.held);
    assert_eq!(first.by_me, Some(true));
    assert_eq!(first.expires_at, Some(now.plus_seconds(TTL_SECONDS)));

    let contested = locks::acquire(
        &server.db,
        a.user_id,
        &node,
        b.device_id,
        now.plus_seconds(TTL_SECONDS - 1),
    )
    .await
    .unwrap();
    assert_eq!(contested.by_me, Some(false), "a live lock is never stolen");
    assert_eq!(
        contested.expires_at, first.expires_at,
        "nor refreshed by the contender"
    );

    let taken = locks::acquire(
        &server.db,
        a.user_id,
        &node,
        b.device_id,
        now.plus_seconds(TTL_SECONDS + 1),
    )
    .await
    .unwrap();
    assert_eq!(taken.by_me, Some(true), "an expired lock is free to take");
    assert_eq!(
        taken.expires_at,
        Some(now.plus_seconds(2 * TTL_SECONDS + 1))
    );

    let released = locks::release(
        &server.db,
        a.user_id,
        &node,
        a.device_id,
        now.plus_seconds(TTL_SECONDS + 2),
    )
    .await
    .unwrap();
    assert!(
        !released.released,
        "the old holder cannot release the new holder's lock"
    );
}
