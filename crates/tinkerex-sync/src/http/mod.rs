//! The v1 wire: axum router, the request extractors, and the state every handler shares.

pub mod cable;
pub mod handlers;

use std::sync::Arc;

use axum::Router;
use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, FromRequest, FromRequestParts, Request};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::http::{HeaderMap, header};
use axum::routing::{delete, get, post, put};
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::timeout::TimeoutLayer;
use tower_http::trace::TraceLayer;

use crate::auth::{Identity, authenticate};
use crate::config::Config;
use crate::db::Db;
use crate::error::ApiError;
use crate::services::nudge::Hub;
use crate::store::ChunkStore;
use crate::time::Timestamp;

pub struct AppState {
    pub db: Db,
    pub store: ChunkStore,
    pub config: Config,
    pub hub: Hub,
}

pub type State = Arc<AppState>;

/// The control plane's JSON bodies: a 100,000-entry manifest is roughly 10 MiB, so `/v1/commit`
/// gets room for it and every other JSON route stays small.
pub const COMMIT_BODY_LIMIT: usize = 16 * 1024 * 1024;
pub const JSON_BODY_LIMIT: usize = 1024 * 1024;
/// The blob tier's per-chunk cap (FastCDC chunks are KB-scale); one byte more is read so the
/// handler can answer the Rails-shaped 413 itself.
pub const BLOB_MAX_BYTES: usize = 64 * 1024 * 1024;
/// A request that has not answered in this long is cut off with 408. Generous, because a blob
/// PUT of 64 MiB over a slow link is a legitimate request; the websocket is exempt (its upgrade
/// answers at once and the socket lives outside the request future).
pub const REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// Every route the binary serves, for the coverage guard and `tinkerex-sync routes`.
pub const ROUTES: &[(&str, &str)] = &[
    ("GET", "/up"),
    ("GET", "/v1/devices/whoami"),
    ("POST", "/v1/devices"),
    ("DELETE", "/v1/devices/:id"),
    ("POST", "/v1/commit"),
    ("POST", "/v1/commit/:commit_id/finalize"),
    ("GET", "/v1/changes"),
    ("GET", "/v1/tree"),
    ("GET", "/v1/search"),
    ("POST", "/v1/nodes"),
    ("POST", "/v1/nodes/symlink"),
    ("DELETE", "/v1/nodes/:node_id"),
    ("POST", "/v1/nodes/:node_id/move"),
    ("GET", "/v1/nodes/:node_id/versions"),
    ("POST", "/v1/nodes/:node_id/restore"),
    ("POST", "/v1/nodes/:node_id/resolve_conflict"),
    ("GET", "/v1/conflicts"),
    ("GET", "/v1/trash"),
    ("POST", "/v1/trash/:node_id/restore"),
    ("POST", "/v1/nodes/:node_id/lock"),
    ("POST", "/v1/nodes/:node_id/unlock"),
    ("GET", "/v1/locks"),
    ("POST", "/v1/chunks/download"),
    ("POST", "/v1/share_links"),
    ("DELETE", "/v1/share_links/:id"),
    ("GET", "/v1/share/:token"),
    ("POST", "/v1/share/:token/download"),
    ("PUT", "/v1/chunks/blob/:user_id/:hash"),
    ("GET", "/v1/chunks/blob/:user_id/:hash"),
    ("POST", "/v1/admin/libraries"),
    ("GET", "/cable"),
];

pub fn router(state: State) -> Router {
    use handlers::*;
    Router::new()
        .route("/up", get(up))
        .route("/v1/devices/whoami", get(whoami))
        .route("/v1/devices", post(devices_create))
        .route("/v1/devices/{id}", delete(devices_destroy))
        .route(
            "/v1/commit",
            post(commit_begin).layer(DefaultBodyLimit::max(COMMIT_BODY_LIMIT)),
        )
        .route("/v1/commit/{commit_id}/finalize", post(commit_finalize))
        .route("/v1/changes", get(changes))
        .route("/v1/tree", get(tree))
        .route("/v1/search", get(search))
        .route("/v1/nodes", post(mkdir))
        .route("/v1/nodes/symlink", post(symlink))
        .route("/v1/nodes/{node_id}", delete(destroy))
        .route("/v1/nodes/{node_id}/move", post(move_node))
        .route("/v1/nodes/{node_id}/versions", get(versions))
        .route("/v1/nodes/{node_id}/restore", post(restore))
        .route(
            "/v1/nodes/{node_id}/resolve_conflict",
            post(resolve_conflict),
        )
        .route("/v1/nodes/{node_id}/lock", post(lock))
        .route("/v1/nodes/{node_id}/unlock", post(unlock))
        .route("/v1/conflicts", get(conflicts))
        .route("/v1/trash", get(trash_index))
        .route("/v1/trash/{node_id}/restore", post(trash_restore))
        .route("/v1/locks", get(locks_index))
        .route("/v1/chunks/download", post(chunks_download))
        .route("/v1/share_links", post(share_links_create))
        .route("/v1/share_links/{id}", delete(share_links_destroy))
        .route("/v1/share/{token}", get(share_show))
        .route("/v1/share/{token}/download", post(share_download))
        .route(
            "/v1/chunks/blob/{user_id}/{hash}",
            put(blob_upload)
                .layer(DefaultBodyLimit::max(BLOB_MAX_BYTES + 1))
                .get(blob_download),
        )
        .route("/v1/admin/libraries", post(admin_libraries_create))
        // The route-level limits above override this default: axum's DefaultBodyLimit is an
        // extension the innermost layer writes last (tests/limits.rs proves it).
        .layer(DefaultBodyLimit::max(JSON_BODY_LIMIT))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            REQUEST_TIMEOUT,
        ))
        .route("/cable", get(cable::cable))
        .layer(TraceLayer::new_for_http())
        .layer(PropagateRequestIdLayer::x_request_id())
        .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
        .with_state(state)
}

// ---- extractors ------------------------------------------------------------------------------

/// The admitted device and its user (`auth` has the rule); `last_seen_at` is stamped as a side
/// effect, at most once per `LAST_SEEN_RESOLUTION_SECONDS`.
pub struct Auth(pub Identity);

impl FromRequestParts<State> for Auth {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &State) -> Result<Self, Self::Rejection> {
        let header = parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok());
        Ok(Auth(
            authenticate(
                &state.db,
                header,
                Timestamp::now(),
                state.config.device_idle_days,
            )
            .await?,
        ))
    }
}

/// The request's JSON body as a map: empty for no body; a 400 for malformed JSON; a body that is
/// not a JSON object (an array, a scalar) contributes no parameters, as Rails' wrapped `_json`
/// key did for every handler here.
pub struct Body(pub serde_json::Map<String, serde_json::Value>);

impl FromRequest<State> for Body {
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &State) -> Result<Self, Self::Rejection> {
        let is_json = req
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(|ct| ct.to_ascii_lowercase().contains("json"))
            .unwrap_or(true);
        let bytes = Bytes::from_request(req, state).await.map_err(|e| {
            if e.status() == StatusCode::PAYLOAD_TOO_LARGE {
                ApiError::PayloadTooLarge("body too large".into())
            } else {
                ApiError::BadRequest(e.body_text())
            }
        })?;
        if !is_json || bytes.iter().all(u8::is_ascii_whitespace) {
            return Ok(Body(serde_json::Map::new()));
        }
        match serde_json::from_slice::<serde_json::Value>(&bytes) {
            Ok(serde_json::Value::Object(map)) => Ok(Body(map)),
            Ok(_) => Ok(Body(serde_json::Map::new())),
            Err(e) => Err(ApiError::BadRequest(format!("invalid JSON body: {e}"))),
        }
    }
}

/// `request.base_url`: what the client reached us at, honouring a reverse proxy's forwarded
/// headers, so the local blob tier presigns URLs the client can actually follow.
pub fn base_url(headers: &HeaderMap) -> String {
    let first = |name: &str| {
        headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(',').next())
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    let proto = first("x-forwarded-proto").unwrap_or_else(|| "http".to_string());
    let host = first("x-forwarded-host")
        .or_else(|| first("host"))
        .unwrap_or_else(|| "localhost:3000".to_string());
    format!("{proto}://{host}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn base_url_prefers_forwarded_headers() {
        let mut h = HeaderMap::new();
        h.insert("host", HeaderValue::from_static("127.0.0.1:3003"));
        assert_eq!(base_url(&h), "http://127.0.0.1:3003");
        h.insert("x-forwarded-proto", HeaderValue::from_static("https"));
        h.insert(
            "x-forwarded-host",
            HeaderValue::from_static("sync.tinkerex.local, inner"),
        );
        assert_eq!(base_url(&h), "https://sync.tinkerex.local");
    }
}
