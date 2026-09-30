//! tinkerex-sync: the sync server, as one binary.
//!
//! Wire contract: `docs/sync-protocol.md` in the maker repo and the recorded corpus under
//! `conformance/`. Storage conventions shared with the Rails implementation this replaces: see
//! `db/README.md` beside the SQL seam.

pub mod auth;
pub mod config;
pub mod db;
pub mod error;
pub mod http;
pub mod ids;
pub mod models;
pub mod schema;
pub mod services;
pub mod store;
pub mod time;
