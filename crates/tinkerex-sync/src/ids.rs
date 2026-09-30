//! Identifiers, tokens and hashes, each shaped exactly as the Rails implementation shaped them so
//! that credentials and content addresses survive the cutover unchanged.

use base64::Engine as _;
use rand::Rng as _;
use sha2::{Digest as _, Sha256};

/// A chunk hash is a lowercase hex SHA-256 — exactly 64 hex chars. The ONLY shape a client-supplied
/// hash may take before it becomes a storage key or a row; `"../7/deadbeef"` must never escape the
/// per-user prefix on a path-based S3 gateway.
pub fn is_chunk_hash(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Server-minted ids (`version_id`, split siblings): lowercase hyphenated v4, like `SecureRandom.uuid`.
pub fn new_uuid() -> String {
    uuid::Uuid::new_v4().hyphenated().to_string()
}

/// `SecureRandom.urlsafe_base64(32)`: 32 random bytes, base64url, no padding — 43 characters.
pub fn new_token() -> String {
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// `Digest::SHA256.hexdigest(token)` — what `devices.token_digest` and `share_links.token_digest` hold.
pub fn sha256_hex(input: &[u8]) -> String {
    hex::encode(Sha256::digest(input))
}

/// `manifest_id = SHA-256 of the ordered chunk-hash list`, hex strings concatenated — the same
/// formula the Rust client's `sync_client::manifest_id` computes, so dedup needs no round trip.
pub fn manifest_id(hashes: impl IntoIterator<Item = impl AsRef<str>>) -> String {
    let mut h = Sha256::new();
    for hash in hashes {
        h.update(hash.as_ref().as_bytes());
    }
    hex::encode(h.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_hash_shape() {
        assert!(is_chunk_hash(&"a".repeat(64)));
        assert!(is_chunk_hash(&"0".repeat(64)));
        assert!(!is_chunk_hash(&"A".repeat(64)), "uppercase is refused");
        assert!(!is_chunk_hash(&"a".repeat(63)));
        assert!(!is_chunk_hash("../7/deadbeef"));
        assert!(!is_chunk_hash("not-a-real-hash"));
    }

    #[test]
    fn tokens_are_43_urlsafe_chars_and_digest_like_ruby() {
        let t = new_token();
        assert_eq!(t.len(), 43);
        assert!(
            t.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        );
        assert_ne!(t, new_token());
        // Digest::SHA256.hexdigest("abc")
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn manifest_id_matches_the_client_formula() {
        // sync-client's own test: sha256("aabb") for hashes ["aa", "bb"].
        assert_eq!(manifest_id(["aa", "bb"]), sha256_hex(b"aabb"));
    }
}
