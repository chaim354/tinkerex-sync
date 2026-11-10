#!/usr/bin/env bash
#
# migrate-chunks.sh — copy the content-addressed `chunks/` keyspace between the
# SeaweedFS source store and a Cloudflare R2 bucket, using rclone.
#
# WHY THIS IS SAFE TO RE-RUN:
#   Chunks are immutable + content-addressed: every object lives at
#   chunks/<user_id>/<sha256> and the bytes EQUAL their hash (docs/r2-migration.md §3.5).
#   So a migration is an idempotent copy of a keyspace:
#     - `rclone copy` only transfers objects missing/different at the destination,
#       so re-running fills gaps (resumable) and a finished run is a no-op.
#     - `rclone check` compares hashes; content-addressing makes a hash match
#       authoritative proof the destination object is the right bytes — but its EXIT
#       STATUS is not that claim (see the `check` arm below, which is what enforces it).
#     - The SOURCE is never modified by `copy`/`check`, so rollback data stays intact.
#
# rclone remotes are configured ENTIRELY via env vars (RCLONE_CONFIG_<NAME>_*), so:
#     - no rclone.conf file is read or written,
#     - no secrets are passed on the command line (they live in env), and
#     - we avoid the `:backend,opt=val:path` connection-string colon-parsing pitfall.
#
# DO NOT hardcode secrets. All endpoints/creds come from the environment (see
# r2.env.example). This script touches storage only; it never touches the server.
#
set -euo pipefail

# Only the content-addressed chunk keyspace moves — nothing else in the bucket.
# HARDCODED, deliberately not a knob: Storage::ChunkStore#key_for builds
# "chunks/<user_id>/<hash>" as a literal with no ENV read, so a CHUNK_PREFIX override here
# could only ever point this tooling at a keyspace the server does not use.
PREFIX="chunks"

# Throughput knobs (override via env if needed).
TRANSFERS="${RCLONE_TRANSFERS:-32}"
CHECKERS="${RCLONE_CHECKERS:-64}"

# Paths are display-only until configure() validates the creds (so `help` needs no env).
SEAWEED_PATH="seaweed:${SEAWEED_BUCKET:-<SEAWEED_BUCKET>}/${PREFIX}"
R2_PATH="r2:${R2_BUCKET:-<R2_BUCKET>}/${PREFIX}"

# rclone reads EVERY one of its flags from RCLONE_<FLAG> in the environment, and — PROBED
# against rclone v1.74.3, not inferred — THE ENVIRONMENT BEATS AN EXPLICIT COMMAND-LINE FLAG:
#     RCLONE_SIZE_ONLY=true rclone check --size-only=false SRC DST
#         -> still compares by SIZE ONLY; a same-size, different-bytes object reads as a match
#     RCLONE_DRY_RUN=true   rclone copy  --dry-run=false   SRC DST
#         -> still copies NOTHING and exits 0 ("Skipped copy as --dry-run is set")
# So "just pass the negating flag" does NOT close this, and a flag that LOOKS like the guard
# while doing nothing is worse than no guard at all. The only thing that works is the variable
# not being in the environment when rclone runs. This script is configured ENTIRELY through the
# environment (see the header) and `r2.env` is sourced into the same shell, so that environment
# is precisely where a stray override comes from.
#
# ALLOWLIST, not a list of the dangerous ones: the set that silently weakens an answer here is
# open-ended — --size-only, --ignore-checksum, --ignore-size, --ignore-existing, --dry-run,
# --max-depth, every --filter/--exclude/--include (which narrow the copy AND the check in step,
# so the check still "passes" over a partial copy), --min-size, --max-age, --one-way, and
# RCLONE_CONFIG itself, which would make this file own "no rclone.conf is read" claim false.
# Enumerating the bad ones is the skip-list shape that keeps failing in this repo.
#
# REFUSE rather than silently unset: an operator who set one on purpose has to be told it is not
# being honoured here.
# NOT named RCLONE_* — `${!RCLONE_@}` below enumerates SHELL variables, so an allowlist called
# RCLONE_ENV_ALLOWED puts itself on the list it defines and refuses every run. (Found by the
# hand-run harness on the first green case, not by reading it.) `${!RCLONE_@}` is the right
# instrument even so: this is a separate process, so the only RCLONE_* names it can see are the
# ones the parent EXPORTED — exactly what rclone will see — plus whatever this file declares.
ALLOWED_RCLONE_ENV=" RCLONE_TRANSFERS RCLONE_CHECKERS "

refuse_rclone_env_overrides() {
  local name stray=""
  for name in ${!RCLONE_@}; do
    case "$ALLOWED_RCLONE_ENV" in *" $name "*) continue ;; esac
    stray="${stray} ${name}"
  done
  [ -z "$stray" ] && return 0
  echo "REFUSING TO RUN — rclone override(s) present in the environment:${stray}" >&2
  echo "  rclone takes every flag from RCLONE_<FLAG>, and the ENVIRONMENT WINS OVER an explicit" >&2
  echo "  command-line flag (verified, rclone v1.74.3). One of these can silently turn 'check'" >&2
  echo "  into a size comparison, or 'copy' into a no-op that still reports success." >&2
  echo "  Unset them (check r2.env — it is sourced into this shell) and re-run." >&2
  echo "  Only these are honoured here:${ALLOWED_RCLONE_ENV}" >&2
  exit 2
}

# configure() — validate creds (from env; source r2.env first) and wire the rclone
# remotes ENTIRELY via env vars (no rclone.conf, no connection-string parsing). Called
# only by commands that actually touch storage, so `help` works without any env set.
configure() {
  # Must run BEFORE this function exports its own RCLONE_CONFIG_* keys.
  refuse_rclone_env_overrides

  # SeaweedFS (source) — the store config/deploy.yml currently points at.
  : "${SEAWEED_ENDPOINT:?set SEAWEED_ENDPOINT, e.g. http://192.168.1.8:8333}"
  : "${SEAWEED_BUCKET:?set SEAWEED_BUCKET, e.g. my-bucket}"
  : "${SEAWEED_ACCESS_KEY_ID:?set SEAWEED_ACCESS_KEY_ID}"
  : "${SEAWEED_SECRET_ACCESS_KEY:?set SEAWEED_SECRET_ACCESS_KEY}"
  local seaweed_region="${SEAWEED_REGION:-us-east-1}"

  # Cloudflare R2 (destination).
  : "${R2_ENDPOINT:?set R2_ENDPOINT, e.g. https://<ACCOUNT_ID>.r2.cloudflarestorage.com}"
  : "${R2_BUCKET:?set R2_BUCKET, e.g. maker-chunks-prod}"
  : "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID (R2 token Access Key ID)}"
  : "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY (R2 token Secret Access Key)}"
  local r2_region="${R2_REGION:-auto}"

  # Remote names: "seaweed" and "r2" → env keys RCLONE_CONFIG_SEAWEED_* / _R2_*.
  export RCLONE_CONFIG_SEAWEED_TYPE="s3"
  export RCLONE_CONFIG_SEAWEED_PROVIDER="Other"
  export RCLONE_CONFIG_SEAWEED_ENDPOINT="$SEAWEED_ENDPOINT"
  export RCLONE_CONFIG_SEAWEED_ACCESS_KEY_ID="$SEAWEED_ACCESS_KEY_ID"
  export RCLONE_CONFIG_SEAWEED_SECRET_ACCESS_KEY="$SEAWEED_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_SEAWEED_REGION="$seaweed_region"
  export RCLONE_CONFIG_SEAWEED_FORCE_PATH_STYLE="true"

  export RCLONE_CONFIG_R2_TYPE="s3"
  export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
  export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_REGION="$r2_region"

  SEAWEED_PATH="seaweed:${SEAWEED_BUCKET}/${PREFIX}"
  R2_PATH="r2:${R2_BUCKET}/${PREFIX}"
}

usage() {
  cat <<EOF
Usage: $0 <command>

Commands (run in this order for a cutover):
  dry-run     Show what the bulk SeaweedFS -> R2 copy WOULD transfer (no writes).
  copy        Bulk copy SeaweedFS -> R2 (idempotent/resumable; source untouched).
  check       Verify SeaweedFS == R2 by hash (authoritative for content-addressed data).
  incremental Final top-up copy SeaweedFS -> R2 (run right AFTER the cutover flip to
              catch chunks written during the bulk copy window). Same as 'copy'; named
              for the runbook step.
  rollback    Reverse copy R2 -> SeaweedFS (backfill chunks that landed ONLY in R2 during
              the R2 window, BEFORE reverting the server env). Source (R2) untouched.

Source: ${SEAWEED_PATH}
Dest:   ${R2_PATH}

All endpoints/creds come from env (see r2.env.example). NEVER hardcode secrets.
EOF
}

# Loud banner so an operator always sees direction + paths before bytes move.
announce() {
  echo "================================================================"
  echo " rclone $1"
  echo "   FROM: $2"
  echo "   TO:   $3"
  echo "   transfers=${TRANSFERS} checkers=${CHECKERS}"
  echo "================================================================"
}

cmd="${1:-}"
case "$cmd" in
  dry-run)
    configure
    announce "copy --dry-run (NO WRITES)" "$SEAWEED_PATH" "$R2_PATH"
    rclone copy --dry-run --progress \
      --transfers="$TRANSFERS" --checkers="$CHECKERS" \
      "$SEAWEED_PATH" "$R2_PATH"
    echo "Dry-run complete. Nothing was written. Re-run with 'copy' to transfer."
    ;;
  copy|incremental)
    configure
    announce "copy (idempotent/resumable)" "$SEAWEED_PATH" "$R2_PATH"
    # There is deliberately NO `--dry-run=false` here, and its absence is the thing to read.
    # RCLONE_DRY_RUN=true in the environment makes this a no-op that still exits 0 and still
    # prints "Copy complete." below — and the negating flag does NOT fix that (probed: the env
    # wins). `refuse_rclone_env_overrides` in configure() is what closes it.
    rclone copy --progress \
      --transfers="$TRANSFERS" --checkers="$CHECKERS" \
      "$SEAWEED_PATH" "$R2_PATH"
    echo "Copy complete (source untouched). Run '$0 check' to verify by hash."
    ;;
  check)
    configure
    announce "check (hash-authoritative)" "$SEAWEED_PATH" "$R2_PATH"
    # WHY THIS IS MORE THAN `rclone check` UNDER `set -e`.
    # `rclone check` exits 0 in FOUR distinct situations, and only the first is the one an
    # operator reads "Check passed" as meaning. Verified against rclone v1.74.3 source
    # (fs/operations/check.go, fs/operations/operations.go, backend/s3/s3.go), not inferred:
    #   1. Every source object present at the destination with an equal hash. The real thing.
    #   2. ZERO objects on BOTH sides — nothing counts objects, so it logs "0 differences
    #      found" and returns nil. A typo'd bucket therefore PASSES.
    #   3. A per-OBJECT missing hash is counted as a MATCH and verified BY SIZE ALONE.
    #      ("No common hash type" is unreachable here — s3.Fs.Hashes() returns MD5
    #      unconditionally and both remotes are type=s3.) `setMD5FromEtag` blanks an
    #      object's md5 unless the ETag is 32 hex chars, so a multipart-uploaded or SSE-KMS
    #      object has no usable hash; `checkHashes` then returns errNoHash and `Match` bumps
    #      the SAME counter a real hash match bumps. The only signal is a NOTICE line,
    #      "<n> hashes could not be checked".
    #   4. `--size-only`. `checkIdentical` short-circuits BEFORE the hash check, so the pair
    #      is emitted as `=` with noHash=false and is not even counted in case 3's total.
    #      Reached from the ENVIRONMENT (RCLONE_SIZE_ONLY=true), which is closed one layer up
    #      by `refuse_rclone_env_overrides` — and NOT, as the obvious remedy assumes, by
    #      passing `--size-only=false` here, which rclone ignores in favour of the env var.
    #      That flag is deliberately absent; read the comment above configure().
    #
    # Counting `=` lines alone does NOT close 3 or 4: rclone emits `=` identically for a
    # size-only match and a hash-verified one, so a bare count would print "N/N verified by
    # hash" over a run that hashed nothing. Hence: count matches against the SOURCE's own
    # object count, refuse an empty source keyspace BY NAME, and refuse any run where rclone
    # reported unchecked hashes (with case 4 already refused before we get here).
    #
    # FRAGILE, PINNED TO A VERSION: the unchecked-hash guard parses a LOG STRING. rclone
    # exposes no exit code and no machine-readable channel for it (`reportResults` logs it and
    # returns nil), so this is the sole default-visible signal and an upstream reword turns the
    # guard off silently. Pinned to rclone v1.74.3 — re-verify on an rclone upgrade, and note
    # you can reach that branch without any S3 at all: point the destination remote at a
    # `crypt` over a local dir (no common hash with `local`), copy into it, then check. On
    # v1.74.3 that prints "N hashes could not be checked", "N matching files" and EXITS 0.
    combined="$(mktemp "${TMPDIR:-/tmp}/r2-cutover-combined.XXXXXX")"
    checkerr="$(mktemp "${TMPDIR:-/tmp}/r2-cutover-stderr.XXXXXX")"
    trap 'rm -f "$combined" "$checkerr"' EXIT
    # stderr goes to a file and is replayed, rather than through a process substitution —
    # a `tee` in a subshell is not guaranteed to have flushed before the greps below read it.
    rc=0
    rclone check --checkers="$CHECKERS" \
      --combined "$combined" \
      "$SEAWEED_PATH" "$R2_PATH" 2>"$checkerr" || rc=$?
    cat "$checkerr" >&2

    # The source's own object count, derived from the combined listing itself — no second
    # listing (and so no extra Class A billing). One line per path considered; `- ` marks a
    # path missing on the SOURCE (destination-only), so every other line was at the source.
    # `grep -c` EXITS 1 when it counts zero, which under `set -euo pipefail` aborts the
    # script at that assignment — hence `|| true` on all three.
    total=$(grep -c "" "$combined" || true)
    dst_only=$(grep -c "^- " "$combined" || true)
    src_n=$((total - dst_only))
    matched=$(grep -c "^= " "$combined" || true)   # `=` == present both sides and identical

    # rclone's own non-zero exit already covers a missing or differing object. Report it with
    # the same numbers as every other refusal below, so an operator reads one vocabulary
    # ("matched/source") rather than two.
    if [ "$rc" -ne 0 ]; then
      echo "" >&2
      echo "CHECK FAILED: rclone exited ${rc}. ${matched}/${src_n} source chunks verified;" \
           "source and destination do NOT match." >&2
      echo "  Combined listing (rclone --combined) is at: ${combined}" >&2
      echo "  Lines: '+' missing at the destination, '*' differing, '!' errored." >&2
      echo "  (The counts come from that listing, which an aborted run may leave incomplete.)" >&2
      trap - EXIT   # keep the listing for the operator to read
      exit "$rc"
    fi

    if [ "$src_n" -eq 0 ]; then
      echo "" >&2
      echo "CHECK FAILED: the source keyspace is EMPTY — nothing was verified." >&2
      echo "  source: ${SEAWEED_PATH}" >&2
      echo "  rclone reports '0 differences found' and exits 0 for two empty keyspaces, so a" >&2
      echo "  wrong bucket, wrong endpoint or wrong prefix would otherwise read as a PASS." >&2
      echo "  If this deploy genuinely has no prior chunk data, skip the migration entirely" >&2
      echo "  (RUNBOOK.md §4) rather than treating this as a successful verification." >&2
      exit 1
    fi

    if grep -qi "hashes could not be checked" "$checkerr"; then
      echo "" >&2
      echo "CHECK FAILED: rclone could not hash some objects, and counted them as MATCHES:" >&2
      grep -i "hashes could not be checked" "$checkerr" >&2
      echo "  Those objects were compared BY SIZE ALONE. For a content-addressed keyspace a" >&2
      echo "  size match proves nothing about the bytes. Usual causes: a multipart-uploaded" >&2
      echo "  object (ETag is a checksum-of-checksums, not the md5) or SSE-KMS. Investigate" >&2
      echo "  before cutting over — do NOT treat this run as verification." >&2
      exit 1
    fi

    if [ "$matched" -ne "$src_n" ]; then
      echo "" >&2
      echo "CHECK FAILED: ${matched}/${src_n} source chunks verified by hash —" \
           "$((src_n - matched)) did not." >&2
      echo "  Combined listing (rclone --combined) is at: ${combined}" >&2
      echo "  Lines: '+' missing at the destination, '*' differing, '!' errored." >&2
      trap - EXIT   # keep the listing for the operator to read
      exit 1
    fi

    echo "Check passed: ${matched}/${src_n} chunks verified by hash" \
         "(no rclone env overrides; rclone reported no unchecked hashes)."
    ;;
  rollback)
    configure
    announce "ROLLBACK copy R2 -> SeaweedFS (backfill R2-only chunks)" "$R2_PATH" "$SEAWEED_PATH"
    echo "This backfills SeaweedFS with any chunks written ONLY to R2 during the R2"
    echo "window. Run this BEFORE reverting the server env, then verify, then revert."
    rclone copy --progress \
      --transfers="$TRANSFERS" --checkers="$CHECKERS" \
      "$R2_PATH" "$SEAWEED_PATH"
    echo "Rollback backfill complete. Verify with: rclone check $R2_PATH $SEAWEED_PATH"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
