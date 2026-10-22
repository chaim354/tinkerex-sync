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

// ---- revocation and idle expiry reach an open socket (tinkerex#473) --------------------------

const DISCONNECT: &str = r#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#;

/// `watch`, but also reporting how long after `start` the server closed the socket (`None`: it
/// was still open when the window ended).
fn watch_until_closed(
    url: String,
    window: Duration,
    start: Instant,
) -> (Vec<Value>, Option<Duration>) {
    let (mut socket, _resp) = tungstenite::connect(&url).expect("websocket handshake");
    match socket.get_mut() {
        MaybeTlsStream::Plain(s) => s
            .set_read_timeout(Some(Duration::from_millis(100)))
            .expect("read timeout"),
        _ => unreachable!("no TLS in this test"),
    }
    let subscribe = json!({ "command": "subscribe", "identifier": CLIENT_IDENTIFIER }).to_string();
    socket
        .send(Message::Text(subscribe.into()))
        .expect("send subscribe");
    let mut frames = Vec::new();
    let deadline = start + window;
    while Instant::now() < deadline {
        match socket.read() {
            Ok(Message::Text(t)) => frames.push(serde_json::from_str(&t).expect("a JSON frame")),
            Ok(Message::Close(_)) => return (frames, Some(start.elapsed())),
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(_) => return (frames, Some(start.elapsed())),
        }
    }
    (frames, None)
}

fn disconnect() -> Value {
    serde_json::from_str(DISCONNECT).unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_revoke_door_cuts_the_revoked_devices_open_socket_at_once_and_no_other() {
    // The default 60 s re-check: anything faster than that below is the hub's event.
    let server = TestServer::start().await;
    let library = server
        .issue_device("cable-revoke@test.example", "library")
        .await;
    let doomed = server.mint(&library.device_token, "doomed").await;
    let start = Instant::now();
    let (doomed_url, library_url) = (
        server.ws_url(&doomed.device_token),
        server.ws_url(&library.device_token),
    );
    let doomed_watch = tokio::task::spawn_blocking(move || {
        watch_until_closed(doomed_url, Duration::from_secs(5), start)
    });
    let library_watch = tokio::task::spawn_blocking(move || {
        watch_until_closed(library_url, Duration::from_millis(2000), start)
    });
    tokio::time::sleep(Duration::from_millis(400)).await;
    let revoked_at = start.elapsed();
    assert_eq!(
        server
            .revoke(&library.device_token, &doomed.device_id.to_string())
            .await
            .0,
        204
    );
    let (frames, closed) = doomed_watch.await.expect("watcher");
    assert_eq!(frames[0], json!({ "type": "welcome" }), "{frames:?}");
    assert_eq!(frames.last(), Some(&disconnect()), "{frames:?}");
    let closed = closed.expect("the revoked device's socket must be closed");
    assert!(
        closed - revoked_at < Duration::from_secs(2),
        "closed {closed:?} after start, the revocation was at {revoked_at:?}"
    );

    let (frames, closed) = library_watch.await.expect("watcher");
    assert_eq!(closed, None, "the library credential's socket stays open");
    assert!(!frames.contains(&disconnect()), "{frames:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_revoked_or_idled_out_token_is_refused_at_connect() {
    let server = TestServer::start().await;
    let library = server
        .issue_device("cable-refused@test.example", "library")
        .await;
    let revoked = server.mint(&library.device_token, "revoked").await;
    let idle = server.mint(&library.device_token, "idle").await;
    assert_eq!(
        server
            .revoke(&library.device_token, &revoked.device_id.to_string())
            .await
            .0,
        204
    );
    server
        .set_device_time(
            idle.device_id,
            "last_seen_at",
            Some(tinkerex_sync::time::Timestamp::now().minus_seconds(91 * support::DAY)),
        )
        .await;
    for token in [revoked.device_token, idle.device_token] {
        let url = server.ws_url(&token);
        let frames = tokio::task::spawn_blocking(move || {
            watch(url, CLIENT_IDENTIFIER, Duration::from_millis(800))
        })
        .await
        .expect("watcher");
        assert_eq!(frames, vec![disconnect()]);
    }
}

/// The operator's `device revoke` runs in another process, so no hub event announces it: the
/// socket's re-check is what reaches it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_out_of_process_revocation_reaches_an_open_socket_by_the_recheck() {
    let server = TestServer::start_tuned(|c| c.cable_recheck = Duration::from_millis(300)).await;
    let library = server
        .issue_device("cable-operator@test.example", "library")
        .await;
    let doomed = server.mint(&library.device_token, "doomed").await;
    let start = Instant::now();
    let url = server.ws_url(&doomed.device_token);
    let watcher =
        tokio::task::spawn_blocking(move || watch_until_closed(url, Duration::from_secs(4), start));
    tokio::time::sleep(Duration::from_millis(500)).await;
    tinkerex_sync::services::revocation::revoke_as_operator(
        &server.db,
        doomed.device_id,
        tinkerex_sync::time::Timestamp::now(),
    )
    .await
    .unwrap()
    .expect("a known id");
    let (frames, closed) = watcher.await.expect("watcher");
    assert_eq!(frames.last(), Some(&disconnect()), "{frames:?}");
    assert!(closed.is_some(), "{frames:?}");
}

/// A device holding its socket open is in use: the re-check stamps `last_seen_at`, so it never
/// idles out while connected -- and once its clock IS past the limit, the socket is cut.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_open_socket_keeps_its_device_in_use_and_is_cut_when_it_idles_out() {
    let server = TestServer::start_tuned(|c| c.cable_recheck = Duration::from_millis(200)).await;
    let library = server
        .issue_device("cable-idle@test.example", "library")
        .await;
    let device = server.mint(&library.device_token, "connected").await;
    let start = Instant::now();
    let url = server.ws_url(&device.device_token);
    let watcher =
        tokio::task::spawn_blocking(move || watch_until_closed(url, Duration::from_secs(5), start));
    tokio::time::sleep(Duration::from_millis(400)).await;

    let now = tinkerex_sync::time::Timestamp::now();
    let stale = now.minus_seconds(tinkerex_sync::models::LAST_SEEN_RESOLUTION_SECONDS + 1);
    server
        .set_device_time(device.device_id, "last_seen_at", Some(stale))
        .await;
    tokio::time::sleep(Duration::from_millis(700)).await;
    let seen = server
        .device_time(device.device_id, "last_seen_at")
        .await
        .expect("stamped");
    assert!(
        seen >= now,
        "the open socket's re-check must stamp the device in use: {seen:?}"
    );

    server
        .set_device_time(
            device.device_id,
            "last_seen_at",
            Some(now.minus_seconds(91 * support::DAY)),
        )
        .await;
    let (frames, closed) = watcher.await.expect("watcher");
    assert_eq!(frames.last(), Some(&disconnect()), "{frames:?}");
    assert!(closed.is_some(), "{frames:?}");
}
