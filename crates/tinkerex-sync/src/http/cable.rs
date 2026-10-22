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
//!
//! A socket outlives any one request, so admission is not a one-time check here (tinkerex#473).
//! The token is admitted by `auth::admit_token`, the rule every HTTP route uses; then the open
//! socket is cut with that same unauthorized `disconnect` frame the moment the revoke door names
//! its device (a hub event), and re-admitted every `cable_recheck` -- which catches what no event
//! announces (the operator's `device revoke` runs in another process; idle expiry is a clock) and
//! stamps `last_seen_at`, so a device holding its socket open is a device in use and never idles
//! out while it does.

use std::collections::HashMap;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State as AxumState};
use axum::response::Response;
use serde_json::{Value, json};

use super::State;
use crate::auth::{admit_token, readmit};
use crate::error::ApiError;
use crate::services::nudge::Event;
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
    let admitted = admit_token(
        &state.db,
        &token,
        Timestamp::now(),
        state.config.device_idle_days,
    )
    .await
    .ok()
    .map(|id| (id.user.id, id.device.id));
    ws.protocols([PROTOCOL])
        .on_upgrade(move |socket| session(socket, state, admitted))
}

async fn send(socket: &mut WebSocket, v: Value) -> bool {
    socket
        .send(Message::Text(v.to_string().into()))
        .await
        .is_ok()
}

/// What a bad token gets, and what an admitted socket gets once its device stops being admitted.
async fn refuse(mut socket: WebSocket) {
    let _ = send(
        &mut socket,
        json!({ "type": "disconnect", "reason": "unauthorized", "reconnect": false }),
    )
    .await;
    let _ = socket.send(Message::Close(None)).await;
}

/// Whether the device may keep its socket. A database error keeps it (the next re-check tries
/// again); only a refusal cuts it.
async fn still_admitted(state: &State, device_id: i64) -> bool {
    match readmit(
        &state.db,
        device_id,
        Timestamp::now(),
        state.config.device_idle_days,
    )
    .await
    {
        Err(ApiError::Unauthorized) => false,
        Err(e) => {
            tracing::warn!(device_id, error = %e, "cable re-check failed; keeping the socket");
            true
        }
        Ok(()) => true,
    }
}

async fn session(mut socket: WebSocket, state: State, admitted: Option<(i64, i64)>) {
    let Some((user_id, device_id)) = admitted else {
        return refuse(socket).await;
    };
    if !send(&mut socket, json!({ "type": "welcome" })).await {
        return;
    }
    let mut events = state.hub.subscribe(user_id);
    // A revocation that landed between admission and the subscription above sent its event to no
    // one; one re-check now closes that window rather than leaving it to the first tick.
    if !still_admitted(&state, device_id).await {
        return refuse(socket).await;
    }
    let mut subscriptions: Vec<String> = Vec::new();
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.tick().await; // the first tick fires immediately; Rails' first ping comes after the interval
    let mut recheck = tokio::time::interval(state.config.cable_recheck);
    recheck.tick().await;
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
            event = events.recv() => {
                match event {
                    Ok(Event::Head(seq)) => {
                        for identifier in subscriptions.clone() {
                            if !send(&mut socket, json!({ "identifier": identifier, "message": { "head_seq": seq } })).await {
                                return;
                            }
                        }
                    }
                    Ok(Event::Revoked(ids)) => {
                        if ids.contains(&device_id) {
                            return refuse(socket).await;
                        }
                    }
                    // A lagging socket may have missed a revocation among what it dropped.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                        if !still_admitted(&state, device_id).await {
                            return refuse(socket).await;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
            _ = recheck.tick() => {
                if !still_admitted(&state, device_id).await {
                    return refuse(socket).await;
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
