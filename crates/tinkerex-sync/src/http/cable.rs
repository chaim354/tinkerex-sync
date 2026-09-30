//! `/cable`: the realtime nudge over Action Cable's own framing, so the deployed Rust client's
//! `watch_library` works unchanged. Measured against the Ruby host on 2026-09-30 (plan §0.2):
//!   - a connection with NO `Origin` header — which is what the Rust client sends — was refused
//!     with a 404 ("Request origin not allowed"), so the deployed daemon has only ever polled;
//!   - with an allowed origin, the client's identifier `{"channel":"LibraryChannel"}` was
//!     `welcome`d and then never confirmed (the class is `Sync::LibraryChannel` there); the
//!     namespaced spelling was confirmed;
//!   - a bad token got `{"type":"disconnect","reason":"unauthorized","reconnect":false}` + close.
//!
//! This endpoint therefore checks no origin (the device token in the query IS the authorization —
//! there is no browser session to forge), accepts BOTH channel spellings, and reproduces the
//! welcome / confirm_subscription / 3-second ping / disconnect frames byte for byte.

use std::collections::HashMap;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State as AxumState};
use axum::response::Response;
use serde_json::{Value, json};

use super::State;
use crate::ids::sha256_hex;
use crate::models::Device;
use crate::time::Timestamp;

pub const PROTOCOL: &str = "actioncable-v1-json";
const PING_INTERVAL: Duration = Duration::from_secs(3);

fn channel_recognised(identifier: &str) -> bool {
    serde_json::from_str::<Value>(identifier)
        .ok()
        .and_then(|v| v.get("channel").and_then(Value::as_str).map(str::to_string))
        .map(|c| c == "LibraryChannel" || c == "Sync::LibraryChannel")
        .unwrap_or(false)
}

pub async fn cable(
    ws: WebSocketUpgrade,
    AxumState(state): AxumState<State>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let token = q.get("token").cloned().unwrap_or_default();
    let mut db = state.db.clone();
    let user_id = if token.is_empty() {
        None
    } else {
        Device::find_by_digest(&mut db, &sha256_hex(token.as_bytes()))
            .await
            .ok()
            .flatten()
            .map(|d| d.user_id)
    };
    ws.protocols([PROTOCOL])
        .on_upgrade(move |socket| session(socket, state, user_id))
}

async fn send(socket: &mut WebSocket, v: Value) -> bool {
    socket
        .send(Message::Text(v.to_string().into()))
        .await
        .is_ok()
}

async fn session(mut socket: WebSocket, state: State, user_id: Option<i64>) {
    let Some(user_id) = user_id else {
        let _ = send(
            &mut socket,
            json!({ "type": "disconnect", "reason": "unauthorized", "reconnect": false }),
        )
        .await;
        let _ = socket.send(Message::Close(None)).await;
        return;
    };
    if !send(&mut socket, json!({ "type": "welcome" })).await {
        return;
    }
    let mut nudges = state.hub.subscribe(user_id);
    let mut subscriptions: Vec<String> = Vec::new();
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.tick().await; // the first tick fires immediately; Rails' first ping comes after the interval
    loop {
        tokio::select! {
            incoming = socket.recv() => {
                let Some(Ok(msg)) = incoming else { break };
                match msg {
                    Message::Text(text) => {
                        let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
                        let command = v.get("command").and_then(Value::as_str).unwrap_or("");
                        let identifier = v.get("identifier").and_then(Value::as_str).unwrap_or("").to_string();
                        match command {
                            "subscribe" if channel_recognised(&identifier) => {
                                if !subscriptions.contains(&identifier) {
                                    subscriptions.push(identifier.clone());
                                }
                                if !send(&mut socket, json!({ "identifier": identifier, "type": "confirm_subscription" })).await {
                                    break;
                                }
                            }
                            "unsubscribe" => subscriptions.retain(|s| s != &identifier),
                            // An unknown channel is logged and ignored, as Action Cable does.
                            _ => tracing::debug!(command, identifier, "cable command ignored"),
                        }
                    }
                    Message::Ping(payload) => {
                        if socket.send(Message::Pong(payload)).await.is_err() { break; }
                    }
                    Message::Close(_) => break,
                    _ => {}
                }
            }
            nudge = nudges.recv() => {
                match nudge {
                    Ok(seq) => {
                        for identifier in subscriptions.clone() {
                            if !send(&mut socket, json!({ "identifier": identifier, "message": { "head_seq": seq } })).await {
                                return;
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
            _ = ping.tick() => {
                if !send(&mut socket, json!({ "type": "ping", "message": Timestamp::now().unix_seconds() })).await {
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_channel_spellings_are_recognised() {
        assert!(channel_recognised(r#"{"channel":"LibraryChannel"}"#));
        assert!(channel_recognised(r#"{"channel":"Sync::LibraryChannel"}"#));
        assert!(!channel_recognised(r#"{"channel":"OtherChannel"}"#));
        assert!(!channel_recognised("not json"));
    }
}
