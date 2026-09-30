//! One handler per route. Each translates the request into a service call and the result into
//! the response shape the corpus recorded; nothing here holds business logic.

use std::collections::BTreeMap;

use axum::Json;
use axum::body::Bytes;
use axum::extract::{Path, Query, State as AxumState};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};

use super::{Auth, BLOB_MAX_BYTES, Body, State, base_url};
use crate::auth::authorize_admin;
use crate::error::{ApiError, ApiResult};
use crate::ids::is_chunk_hash;
use crate::models::{User, known_chunk_hashes};
use crate::services::params::{
    clamp, opt_str, opt_to_i, present_str, require_str, str_to_i, to_bool,
};
use crate::services::{
    changes, commit, conflicts, locks, nodes, provisioning, restore, search, sharing,
    subtree_delete, trash, tree, versions,
};
use crate::time::Timestamp;

type QueryParams = Query<std::collections::HashMap<String, String>>;

fn created(v: Value) -> Response {
    (StatusCode::CREATED, Json(v)).into_response()
}

fn query_i64(q: &QueryParams, key: &str) -> Option<i64> {
    q.get(key).map(|s| str_to_i(s))
}

pub const CHUNKS_DOWNLOAD_MAX: usize = 10_000;

// ---- health ----------------------------------------------------------------------------------

/// Reads the database on purpose: a static 200 tells the proxy to send traffic to an app that
/// cannot serve a request (the first Rails deploy came up "healthy" with an empty schema).
pub async fn up(AxumState(state): AxumState<State>) -> Response {
    let mut db = state.db.clone();
    match User::count(&mut db).await {
        Ok(_) => (StatusCode::OK, [(header::CONTENT_TYPE, "text/plain")], "ok").into_response(),
        Err(e) => (
            StatusCode::SERVICE_UNAVAILABLE,
            [(header::CONTENT_TYPE, "text/plain")],
            format!("not ready: {e}"),
        )
            .into_response(),
    }
}

// ---- devices (the host's own two routes) ------------------------------------------------------

pub async fn whoami(Auth(id): Auth) -> Response {
    Json(json!({ "user_id": id.user.id, "device_id": id.device.id, "head_seq": id.user.head_seq }))
        .into_response()
}

pub async fn devices_create(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Body(body): Body,
) -> ApiResult<Response> {
    let name = present_str(body.get("name")).unwrap_or_else(|| "device".to_string());
    let issued =
        provisioning::register_device(&state.db, id.user.id, &name, Timestamp::now()).await?;
    Ok(created(
        json!({ "device_id": issued.device_id, "device_token": issued.device_token }),
    ))
}

// ---- commits ----------------------------------------------------------------------------------

pub async fn commit_begin(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    headers: HeaderMap,
    Body(body): Body,
) -> ApiResult<Response> {
    let params = commit::begin_params_from(&body, Some(id.device.id));
    let begun = commit::begin(
        &state.db,
        &state.store,
        &base_url(&headers),
        id.user.id,
        params,
        Timestamp::now(),
    )
    .await?;
    Ok(Json(begun).into_response())
}

pub async fn commit_finalize(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(commit_id): Path<String>,
) -> ApiResult<Response> {
    let done = commit::finalize(
        &state.db,
        &state.store,
        id.user.id,
        &commit_id,
        state.config.verify_finalize,
        Timestamp::now(),
    )
    .await?;
    state.hub.publish(id.user.id, done.seq);
    Ok(Json(json!({ "version_id": done.version.version_id, "seq": done.seq })).into_response())
}

// ---- reads ------------------------------------------------------------------------------------

pub async fn changes(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    q: QueryParams,
) -> ApiResult<Response> {
    let since = query_i64(&q, "since").unwrap_or(0);
    let limit = clamp(query_i64(&q, "limit").unwrap_or(500), 1, 2000);
    Ok(Json(changes::call(&state.db, id.user.id, since, limit).await?).into_response())
}

pub async fn tree(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    q: QueryParams,
) -> ApiResult<Response> {
    let after_id = query_i64(&q, "after_id").unwrap_or(0);
    let limit = clamp(query_i64(&q, "limit").unwrap_or(1000), 1, 5000);
    Ok(Json(tree::call(&state.db, id.user.id, after_id, limit).await?).into_response())
}

pub async fn search(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    q: QueryParams,
) -> ApiResult<Response> {
    let query = q.get("q").cloned().unwrap_or_default();
    let include_deleted = q
        .get("include_deleted")
        .map(|s| to_bool(Some(&Value::String(s.clone()))))
        .unwrap_or(false);
    let limit = query_i64(&q, "limit").unwrap_or(search::MAX_LIMIT);
    let offset = query_i64(&q, "offset").unwrap_or(0);
    let results = search::call(
        &state.db,
        id.user.id,
        &query,
        include_deleted,
        limit,
        offset,
    )
    .await?;
    Ok(Json(json!({ "results": results })).into_response())
}

pub async fn versions(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(node_id): Path<String>,
) -> ApiResult<Response> {
    Ok(
        Json(json!({ "versions": versions::list(&state.db, id.user.id, &node_id).await? }))
            .into_response(),
    )
}

pub async fn conflicts(AxumState(state): AxumState<State>, Auth(id): Auth) -> ApiResult<Response> {
    Ok(Json(json!({ "conflicts": conflicts::list(&state.db, id.user.id).await? })).into_response())
}

pub async fn locks_index(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
) -> ApiResult<Response> {
    Ok(Json(json!({ "locks": locks::active(&state.db, id.user.id, Some(id.device.id), Timestamp::now()).await? })).into_response())
}

pub async fn trash_index(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
) -> ApiResult<Response> {
    Ok(Json(json!({ "items": trash::list(&state.db, id.user.id).await? })).into_response())
}

// ---- node mutations ---------------------------------------------------------------------------

pub async fn mkdir(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Body(body): Body,
) -> ApiResult<Response> {
    let node_id = require_str(&body, "node_id")?;
    let seq = nodes::mkdir(
        &state.db,
        id.user.id,
        nodes::MkdirParams {
            node_id: node_id.clone(),
            parent_node_id: opt_str(body.get("parent_node_id")),
            name: opt_str(body.get("name")),
            mode: opt_to_i(body.get("mode")),
            mtime: opt_to_i(body.get("mtime")),
        },
        Timestamp::now(),
    )
    .await?;
    state.hub.publish(id.user.id, seq);
    Ok(created(json!({ "node_id": node_id, "seq": seq })))
}

pub async fn symlink(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Body(body): Body,
) -> ApiResult<Response> {
    let node_id = require_str(&body, "node_id")?;
    let seq = nodes::symlink(
        &state.db,
        id.user.id,
        nodes::SymlinkParams {
            node_id: node_id.clone(),
            parent_node_id: opt_str(body.get("parent_node_id")),
            name: opt_str(body.get("name")),
            symlink_target: present_str(body.get("symlink_target")),
            mode: opt_to_i(body.get("mode")),
            mtime: opt_to_i(body.get("mtime")),
        },
        Timestamp::now(),
    )
    .await?;
    state.hub.publish(id.user.id, seq);
    Ok(created(json!({ "node_id": node_id, "seq": seq })))
}

pub async fn destroy(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(node_id): Path<String>,
) -> ApiResult<Response> {
    let seq = subtree_delete::call(&state.db, id.user.id, &node_id, Timestamp::now()).await?;
    state.hub.publish(id.user.id, seq);
    Ok(Json(json!({ "seq": seq })).into_response())
}

pub async fn move_node(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(node_id): Path<String>,
    Body(body): Body,
) -> ApiResult<Response> {
    let seq = nodes::move_node(
        &state.db,
        id.user.id,
        nodes::MoveParams {
            node_id,
            new_parent: if body.contains_key("new_parent_node_id") {
                Some(opt_str(body.get("new_parent_node_id")))
            } else {
                None
            },
            new_name: present_str(body.get("new_name")),
        },
        Timestamp::now(),
    )
    .await?;
    state.hub.publish(id.user.id, seq);
    Ok(Json(json!({ "seq": seq })).into_response())
}

pub async fn restore(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(node_id): Path<String>,
    Body(body): Body,
) -> ApiResult<Response> {
    let version_id = require_str(&body, "version_id")?;
    let restored = restore::call(
        &state.db,
        id.user.id,
        &node_id,
        &version_id,
        Timestamp::now(),
    )
    .await?;
    state.hub.publish(id.user.id, restored.seq);
    Ok(Json(json!({ "version_id": restored.version_id, "seq": restored.seq })).into_response())
}

pub async fn resolve_conflict(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(node_id): Path<String>,
    Body(body): Body,
) -> ApiResult<Response> {
    if to_bool(body.get("split")) {
        let split = conflicts::split(&state.db, id.user.id, &node_id, Timestamp::now()).await?;
        state.hub.publish(id.user.id, split.seq);
        Ok(Json(json!({ "split_node_id": split.first_node_id, "split_node_ids": split.node_ids, "seq": split.seq })).into_response())
    } else {
        let keep = require_str(&body, "keep_version_id")?;
        let seq = conflicts::keep(&state.db, id.user.id, &node_id, &keep, Timestamp::now()).await?;
        state.hub.publish(id.user.id, seq);
        Ok(Json(json!({ "seq": seq })).into_response())
    }
}

pub async fn lock(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(node_id): Path<String>,
) -> ApiResult<Response> {
    Ok(Json(
        locks::acquire(
            &state.db,
            id.user.id,
            &node_id,
            id.device.id,
            Timestamp::now(),
        )
        .await?,
    )
    .into_response())
}

pub async fn unlock(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(node_id): Path<String>,
) -> ApiResult<Response> {
    Ok(Json(
        locks::release(
            &state.db,
            id.user.id,
            &node_id,
            id.device.id,
            Timestamp::now(),
        )
        .await?,
    )
    .into_response())
}

pub async fn trash_restore(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(node_id): Path<String>,
    Body(body): Body,
) -> ApiResult<Response> {
    let restored = trash::restore(
        &state.db,
        id.user.id,
        &node_id,
        to_bool(body.get("to_root")),
        Timestamp::now(),
    )
    .await?;
    if let Some(seq) = restored.seq {
        state.hub.publish(id.user.id, seq);
    }
    Ok(Json(json!({ "node_id": restored.node_id, "parent_node_id": restored.parent_node_id, "seq": restored.seq })).into_response())
}

// ---- chunks -----------------------------------------------------------------------------------

/// Presigned GETs for the chunks the requester OWNS: an unowned or malformed hash is silently
/// omitted, never an error, so a token cannot fish for keys.
pub async fn chunks_download(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    headers: HeaderMap,
    Body(body): Body,
) -> ApiResult<Response> {
    let mut hashes: Vec<String> = Vec::new();
    for v in body
        .get("hashes")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
    {
        let s = match v {
            Value::String(s) => s.clone(),
            Value::Null => String::new(),
            other => other.to_string(),
        };
        if !hashes.contains(&s) {
            hashes.push(s);
        }
    }
    if hashes.len() > CHUNKS_DOWNLOAD_MAX {
        return Err(ApiError::Unprocessable(format!(
            "too many hashes ({} > {CHUNKS_DOWNLOAD_MAX})",
            hashes.len()
        )));
    }
    let hashes: Vec<String> = hashes.into_iter().filter(|h| is_chunk_hash(h)).collect();
    let mut db = state.db.clone();
    let owned = known_chunk_hashes(&mut db, id.user.id, &hashes).await?;
    let base = base_url(&headers);
    let now = Timestamp::now();
    let urls: BTreeMap<String, String> = hashes
        .iter()
        .filter(|h| owned.contains(*h))
        .map(|h| {
            (
                h.clone(),
                state.store.presign_get(&base, id.user.id, h, now),
            )
        })
        .collect();
    Ok(Json(json!({ "urls": urls })).into_response())
}

fn blob_params(user_id: &str, hash: &str) -> Option<i64> {
    if !hash.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) || hash.is_empty() {
        return None; // the Rails route constraint: no such route
    }
    user_id.parse::<i64>().ok()
}

/// The local blob tier: HMAC in the query string, never a bearer token; 404 unless the active
/// store is `local`; empty or plain-text bodies, never JSON.
pub async fn blob_upload(
    AxumState(state): AxumState<State>,
    Path((user_id, hash)): Path<(String, String)>,
    q: QueryParams,
    body: Bytes,
) -> Response {
    let Some(local) = state.store.local() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(uid) = blob_params(&user_id, &hash) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let exp = query_i64(&q, "exp").unwrap_or(0);
    let sig = q.get("sig").cloned().unwrap_or_default();
    if !local.verify(uid, &hash, exp, &sig, Timestamp::now()) {
        return StatusCode::FORBIDDEN.into_response();
    }
    if body.len() > BLOB_MAX_BYTES {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            [(header::CONTENT_TYPE, "text/plain")],
            "chunk too large",
        )
            .into_response();
    }
    match local.write(uid, &hash, &body).await {
        Ok(()) => StatusCode::OK.into_response(),
        Err(e) => ApiError::Internal(e).into_response(),
    }
}

pub async fn blob_download(
    AxumState(state): AxumState<State>,
    Path((user_id, hash)): Path<(String, String)>,
    q: QueryParams,
) -> Response {
    let Some(local) = state.store.local() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(uid) = blob_params(&user_id, &hash) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let exp = query_i64(&q, "exp").unwrap_or(0);
    let sig = q.get("sig").cloned().unwrap_or_default();
    if !local.verify(uid, &hash, exp, &sig, Timestamp::now()) {
        return StatusCode::FORBIDDEN.into_response();
    }
    match local.read(uid, &hash).await {
        Ok(Some(bytes)) => (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, "application/octet-stream"),
                (header::CONTENT_DISPOSITION, "inline"),
            ],
            bytes,
        )
            .into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => ApiError::Internal(e).into_response(),
    }
}

// ---- share links --------------------------------------------------------------------------------

pub async fn share_links_create(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Body(body): Body,
) -> ApiResult<Response> {
    let node_id = require_str(&body, "node_id")?;
    let version_id = require_str(&body, "version_id")?;
    let expires_at = match body.get("expires_at") {
        Some(Value::String(s)) => Timestamp::parse_user_input(s),
        _ => None,
    };
    let link = sharing::create_for_version(
        &state.db,
        id.user.id,
        &node_id,
        &version_id,
        expires_at,
        Timestamp::now(),
    )
    .await?;
    Ok(created(
        json!({ "id": link.id, "token": link.token, "version_id": link.version_id, "expires_at": link.expires_at }),
    ))
}

pub async fn share_links_destroy(
    AxumState(state): AxumState<State>,
    Auth(id): Auth,
    Path(link_id): Path<String>,
) -> ApiResult<Response> {
    let link_id: i64 = link_id.parse().map_err(|_| ApiError::NotFound)?;
    sharing::revoke(&state.db, id.user.id, link_id, Timestamp::now()).await?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// The anonymous redeem side: no bearer check at all; the token IS the authorization, and a dead
/// one is a 404 whatever the reason.
pub async fn share_show(
    AxumState(state): AxumState<State>,
    Path(token): Path<String>,
) -> ApiResult<Response> {
    let cap = sharing::redeem(&state.db, &token, Timestamp::now())
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(sharing::show(&state.db, &cap).await?).into_response())
}

pub async fn share_download(
    AxumState(state): AxumState<State>,
    Path(token): Path<String>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let now = Timestamp::now();
    let cap = sharing::redeem(&state.db, &token, now)
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(
        Json(
            json!({ "urls": sharing::presign_urls(&state.store, &base_url(&headers), &cap, now) }),
        )
        .into_response(),
    )
}

// ---- admin --------------------------------------------------------------------------------------

/// Gated by `SYNC_ADMIN_TOKEN`, an operator credential a device token can never satisfy.
pub async fn admin_libraries_create(
    AxumState(state): AxumState<State>,
    headers: HeaderMap,
    Body(body): Body,
) -> ApiResult<Response> {
    authorize_admin(
        state.config.admin_token.as_deref(),
        headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok()),
    )?;
    let email = require_str(&body, "email")?;
    let name = present_str(body.get("name")).unwrap_or_else(|| "device".to_string());
    let issued =
        provisioning::provision_library(&state.db, &email, &name, Timestamp::now()).await?;
    Ok(created(
        json!({ "user_id": issued.user_id, "device_id": issued.device_id, "device_token": issued.device_token }),
    ))
}
