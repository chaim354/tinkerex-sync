//! `/cable`, driven exactly as the desktop client drives it. The frames below are copied from
//! `sync-client::watch_library` (`client/sync-client/src/lib.rs` in chaim354/tinkerex-client):
//! a plain `tungstenite::connect` — no `Origin` header, no subprotocol — then one text frame
//! `{"command":"subscribe","identifier":"{\"channel\":\"LibraryChannel\"}"}`, then a read loop
//! that acts only on frames carrying `message.head_seq`. Measured against the Ruby host on
//! 2026-09-30 (plan §0.2), that exact connection was refused (404, no Origin) and that exact
//! identifier was never confirmed; here both work, so these tests pin the behaviour the deployed
//! client gets for the first time.

mod support;

use std::time::{Duration, Instant};

use serde_json::{Value, json};
use support::TestServer;
use tungstenite::Message;
use tungstenite::stream::MaybeTlsStream;

const CLIENT_IDENTIFIER: &str = "{\"channel\":\"LibraryChannel\"}";

/// Subscribe as the client does and collect every text frame for `window`.
fn watch(url: String, identifier: &str, window: Duration) -> Vec<Value> {
    let (mut socket, _resp) = tungstenite::connect(&url).expect("websocket handshake");
    match socket.get_mut() {
        MaybeTlsStream::Plain(s) => s
            .set_read_timeout(Some(Duration::from_millis(250)))
            .expect("read timeout"),
        _ => unreachable!("no TLS in this test"),
    }
    let subscribe = json!({ "command": "subscribe", "identifier": identifier }).to_string();
    socket
        .send(Message::Text(subscribe.into()))
        .expect("send subscribe");
    let mut frames = Vec::new();
    let deadline = Instant::now() + window;
    while Instant::now() < deadline {
        match socket.read() {
            Ok(Message::Text(t)) => frames.push(serde_json::from_str(&t).expect("a JSON frame")),
            Ok(Message::Ping(p)) => {
                let _ = socket.send(Message::Pong(p));
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(_) => break,
        }
    }
    frames
}

async fn mkdir(server: &TestServer, token: &str, name: &str) -> i64 {
    let resp = server
        .http()
        .post(format!("{}/v1/nodes", server.base_url))
        .bearer_auth(token)
        .json(&json!({ "node_id": tinkerex_sync::ids::new_uuid(), "parent_node_id": null, "name": name }))
        .send()
        .await
        .expect("mkdir request");
    assert_eq!(resp.status(), 201);
    resp.json::<Value>().await.expect("json")["seq"]
        .as_i64()
        .expect("seq")
}

fn head_seqs(frames: &[Value], identifier: &str) -> Vec<i64> {
    frames
        .iter()
        .filter(|f| f["identifier"] == identifier)
        .filter_map(|f| f["message"]["head_seq"].as_i64())
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_nudges_the_client_subscribed_exactly_as_watch_library_subscribes() {
    let server = TestServer::start().await;
    let device = server.issue_device("cable@test.example", "device").await;
    let url = server.ws_url(&device.device_token);
    let watcher = tokio::task::spawn_blocking(move || {
        watch(url, CLIENT_IDENTIFIER, Duration::from_millis(1500))
    });
    tokio::time::sleep(Duration::from_millis(400)).await; // let welcome + confirm land first
    let seq = mkdir(&server, &device.device_token, "Nudged").await;
    let frames = watcher.await.expect("watcher");

    assert_eq!(
        frames[0],
        json!({ "type": "welcome" }),
        "frames: {frames:?}"
    );
    assert!(
        frames
            .contains(&json!({ "identifier": CLIENT_IDENTIFIER, "type": "confirm_subscription" })),
        "the client's own identifier must be confirmed; frames: {frames:?}"
    );
    assert_eq!(
        head_seqs(&frames, CLIENT_IDENTIFIER),
        vec![seq],
        "exactly one {{head_seq}} nudge, carrying the mutation's seq; frames: {frames:?}"
    );
    for f in &frames {
        let known = f["type"] == "welcome"
            || f["type"] == "confirm_subscription"
            || f["type"] == "ping"
            || f["message"]["head_seq"].is_i64();
        assert!(known, "an unexpected frame shape: {f}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_namespaced_channel_spelling_is_confirmed_and_nudged_too() {
    let server = TestServer::start().await;
    let device = server.issue_device("cable-ns@test.example", "device").await;
    let url = server.ws_url(&device.device_token);
    let identifier = "{\"channel\":\"Sync::LibraryChannel\"}";
    let watcher =
        tokio::task::spawn_blocking(move || watch(url, identifier, Duration::from_millis(1500)));
    tokio::time::sleep(Duration::from_millis(400)).await;
    let seq = mkdir(&server, &device.device_token, "Nudged").await;
    let frames = watcher.await.expect("watcher");
    assert!(frames.contains(&json!({ "identifier": identifier, "type": "confirm_subscription" })));
    assert_eq!(head_seqs(&frames, identifier), vec![seq]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unknown_token_is_told_unauthorized_and_closed() {
    let server = TestServer::start().await;
    let url = server.ws_url("not-a-real-token");
    let frames = tokio::task::spawn_blocking(move || {
        watch(url, CLIENT_IDENTIFIER, Duration::from_millis(1000))
    })
    .await
    .expect("watcher");
    assert_eq!(
        frames,
        vec![json!({ "type": "disconnect", "reason": "unauthorized", "reconnect": false })]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_unknown_channel_is_welcomed_but_never_confirmed_or_nudged() {
    let server = TestServer::start().await;
    let device = server
        .issue_device("cable-other@test.example", "device")
        .await;
    let url = server.ws_url(&device.device_token);
    let identifier = "{\"channel\":\"OtherChannel\"}";
    let watcher =
        tokio::task::spawn_blocking(move || watch(url, identifier, Duration::from_millis(1000)));
    tokio::time::sleep(Duration::from_millis(300)).await;
    mkdir(&server, &device.device_token, "Unheard").await;
    let frames = watcher.await.expect("watcher");
    assert_eq!(frames[0], json!({ "type": "welcome" }));
    assert!(
        !frames.iter().any(|f| f["type"] == "confirm_subscription"),
        "{frames:?}"
    );
    assert!(head_seqs(&frames, identifier).is_empty(), "{frames:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_nudge_never_crosses_users() {
    let server = TestServer::start().await;
    let a = server.issue_device("cable-a@test.example", "device").await;
    let b = server.issue_device("cable-b@test.example", "device").await;
    let url = server.ws_url(&a.device_token);
    let watcher = tokio::task::spawn_blocking(move || {
        watch(url, CLIENT_IDENTIFIER, Duration::from_millis(1200))
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    mkdir(&server, &b.device_token, "Bs").await;
    let frames = watcher.await.expect("watcher");
    assert!(
        head_seqs(&frames, CLIENT_IDENTIFIER).is_empty(),
        "{frames:?}"
    );
}
