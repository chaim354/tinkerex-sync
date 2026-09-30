//! The error envelope `Sync::V1::BaseController` installed, reproduced status by status:
//!   404 is always the literal `{"error":"not_found"}`, whatever the cause;
//!   400 / 422 / 409 carry the raiser's message; 401 is `{"error":"unauthorized"}`;
//!   `chunks_missing` is its own 422 shape with the `missing` array a client re-uploads from.

use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("not_found")]
    NotFound,
    #[error("unauthorized")]
    Unauthorized,
    #[error("{0}")]
    BadRequest(String),
    #[error("{0}")]
    Unprocessable(String),
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    ServiceUnavailable(String),
    /// A body over the route's limit (plan §3.8); Rails had no limit of its own, so this shape
    /// is the Rust server's alone.
    #[error("{0}")]
    PayloadTooLarge(String),
    #[error("chunks missing")]
    ChunksMissing(Vec<String>),
    #[error("internal: {0}")]
    Internal(#[from] anyhow::Error),
}

pub type ApiResult<T> = Result<T, ApiError>;

impl From<sqlx::Error> for ApiError {
    fn from(e: sqlx::Error) -> Self {
        if let sqlx::Error::Database(db) = &e {
            // Rails: ActiveRecord::RecordNotUnique -> 409, message preserved.
            if db.is_unique_violation() {
                return ApiError::Conflict(db.message().to_string());
            }
        }
        ApiError::Internal(e.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, body) = match &self {
            ApiError::NotFound => (StatusCode::NOT_FOUND, json!({ "error": "not_found" })),
            ApiError::Unauthorized => {
                (StatusCode::UNAUTHORIZED, json!({ "error": "unauthorized" }))
            }
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, json!({ "error": m })),
            ApiError::Unprocessable(m) => (StatusCode::UNPROCESSABLE_ENTITY, json!({ "error": m })),
            ApiError::Conflict(m) => (StatusCode::CONFLICT, json!({ "error": m })),
            ApiError::ServiceUnavailable(m) => {
                (StatusCode::SERVICE_UNAVAILABLE, json!({ "error": m }))
            }
            ApiError::PayloadTooLarge(m) => (StatusCode::PAYLOAD_TOO_LARGE, json!({ "error": m })),
            ApiError::ChunksMissing(missing) => (
                StatusCode::UNPROCESSABLE_ENTITY,
                json!({ "error": "chunks_missing", "missing": missing }),
            ),
            ApiError::Internal(e) => {
                tracing::error!(error = ?e, "request failed");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    json!({ "error": "internal_error" }),
                )
            }
        };
        (status, Json(body)).into_response()
    }
}
