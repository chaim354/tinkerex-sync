#!/usr/bin/env bash
#
# smoke.sh — pre-flight / post-cutover smoke check against a server pointed at R2.
#
# Runs the existing presigned_roundtrip example (device A -> presigned PUT to R2 ->
# device B pulls + hydrates via presigned GET -> byte-for-byte compare) and confirms
# the "PRESIGNED ROUNDTRIP OK" line. This proves the REAL production data plane works
# against R2: presign (server) + PUT/GET (client <-> R2) + head_object verify.
#
# THE ROUNDTRIP PROVES THE BYTES LANDED; IT DOES NOT NAME THE STORE THEY LANDED IN. The
# example enrolls a fresh user every run and dedup is per-user, so every chunk is first-seen
# and the server's finalize verification (ON by default) HEADs its own store — but "its own
# store" is whatever CHUNK_* the server booted with, which during a cutover is precisely the
# thing in question. So the example also prints a `store identity` line, read out of a real
# presigned URL (path-style: origin + first path segment name the endpoint and the bucket),
# and this script CROSS-CHECKS it against R2_ENDPOINT/R2_BUCKET when they are in the
# environment. Nothing else in the repo can make that comparison: the server's CHUNK_BUCKET
# and this tooling's R2_BUCKET are two independently-typed values that nothing reconciles.
#
# The client only needs SERVER_URL; the store is decided by the SERVER's STORAGE_BACKEND
# + CHUNK_* env. So to smoke R2 you point the SERVER at R2 and run this — no client
# change (docs/r2-migration.md §3.4 / §5).
#
# Usage:
#   SERVER_URL=https://<your-server> ./smoke.sh
#   SERVER_URL=https://<your-server> TINKEREX_CLIENT_DIR=/path/to/tinkerex-client ./smoke.sh
#
set -euo pipefail

SERVER_URL="${SERVER_URL:?set SERVER_URL to the Rails server pointed at R2, e.g. https://maker.example.com}"

# Locate the sync-engine crate. client/ moved to its own repo, chaim354/tinkerex-client
# (docs/superpowers/plans/2026-08-20-stage-1-extract-client.md), so it no longer lives under this
# script's own repo root. This is an OPERATOR script run by hand during storage cutovers, not CI —
# nothing goes red when this assumption breaks, so the failure below must be loud and must name
# where to get the crate, not just where it looked.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CLIENT_DIR="${TINKEREX_CLIENT_DIR:-$REPO_ROOT/../tinkerex-client}"
ENGINE_DIR="$CLIENT_DIR/client/sync-engine"

if [ ! -d "$ENGINE_DIR" ]; then
  echo "sync-engine crate not found at $ENGINE_DIR" >&2
  echo "" >&2
  echo "client/ moved to chaim354/tinkerex-client (docs/superpowers/plans/" >&2
  echo "2026-08-20-stage-1-extract-client.md) and is no longer part of this repo. Clone it:" >&2
  echo "    gh repo clone chaim354/tinkerex-client $CLIENT_DIR" >&2
  echo "or, if you already have a checkout elsewhere, point this script at it:" >&2
  echo "    SERVER_URL=... TINKEREX_CLIENT_DIR=/path/to/tinkerex-client $0" >&2
  exit 1
fi

echo "================================================================"
echo " R2 pre-flight smoke: presigned_roundtrip against the data plane"
echo "   SERVER_URL=$SERVER_URL"
echo "   (the server must be configured STORAGE_BACKEND=s3 + R2 CHUNK_*)"
echo "================================================================"
echo "Running the example (this pushes one real chunk to R2 and reads it back)..."

# Capture output so we can assert on the success line and fail loudly otherwise.
out="$(cd "$ENGINE_DIR" && SERVER_URL="$SERVER_URL" cargo run --quiet --example presigned_roundtrip 2>&1)" || {
  echo "$out"
  echo ""
  echo "SMOKE FAILED: the example exited non-zero. R2 data plane is NOT verified." >&2
  exit 1
}

echo "$out"

if ! grep -q "PRESIGNED ROUNDTRIP OK" <<<"$out"; then
  echo ""
  echo "SMOKE FAILED: did not see 'PRESIGNED ROUNDTRIP OK'. R2 data plane is NOT verified." >&2
  exit 1
fi

# --- which store did the server presign against? ------------------------------------------
identity="$(grep -m1 "store identity" <<<"$out" || true)"
if [ -z "$identity" ]; then
  echo ""
  echo "SMOKE FAILED: the example printed no 'store identity' line." >&2
  echo "  That line is what names the endpoint + bucket the server presigned against; without" >&2
  echo "  it a green roundtrip only says 'some store', which is not what a cutover is asking." >&2
  echo "  Rebuild the client from this tree (client/sync-engine/examples/presigned_roundtrip.rs)." >&2
  exit 1
fi
echo ""
echo "$identity"

got_origin="$(sed -n 's/.*withheld): \([^ ]*\) bucket=.*/\1/p' <<<"$identity")"
got_bucket="$(sed -n 's/.*bucket=\(.*\)$/\1/p' <<<"$identity")"

if [ -n "${R2_ENDPOINT:-}" ] && [ -n "${R2_BUCKET:-}" ]; then
  # Compare ORIGIN to origin: R2_ENDPOINT is scheme://host with no path, which is exactly the
  # shape the example prints. A trailing slash is the one difference worth normalising.
  want_origin="${R2_ENDPOINT%/}"
  if [ "$got_origin" != "$want_origin" ] || [ "$got_bucket" != "$R2_BUCKET" ]; then
    echo ""
    echo "SMOKE FAILED: the server is NOT presigning against the bucket this tooling migrated." >&2
    echo "  server presigns : ${got_origin} bucket=${got_bucket}" >&2
    echo "  r2.env expects  : ${want_origin} bucket=${R2_BUCKET}" >&2
    echo "  The bytes round-tripped, so the data plane works — but against a DIFFERENT store" >&2
    echo "  than migrate-chunks.sh filled. Check config/deploy.yml's CHUNK_ENDPOINT/CHUNK_BUCKET" >&2
    echo "  against r2.env before treating the cutover as done." >&2
    exit 1
  fi
  echo "Store identity matches r2.env (R2_ENDPOINT + R2_BUCKET)."
else
  echo "NOTICE: R2_ENDPOINT/R2_BUCKET are not set, so the store identity above was NOT" >&2
  echo "        cross-checked against the bucket migrate-chunks.sh filled — only PRINTED." >&2
  echo "        Source r2.env into this shell (RUNBOOK.md §2) to have it verified." >&2
fi

echo ""
echo "SMOKE OK — real bytes round-tripped byte-for-byte, through the store named above."
