# tinkerex-sync (the Rust server)

The sync server as one binary: the chunk, version and changelog engine behind the v1 API, the
colocated blob tier, the Action Cable nudge, and the operator subcommands the Rails host exposed as
rake tasks. It is graded against `../../conformance/` — sixteen recorded scenario files, verified
by `test/conformance_test.rb` — not against the Ruby tests (`docs/superpowers/plans/2026-09-30-rust-rewrite.md`
says why, and what is done).

```sh
cargo build --release -p tinkerex-sync
target/release/tinkerex-sync --help

tinkerex-sync migrate                        # create the Rails-shaped schema, or adopt a Rails file
tinkerex-sync serve --port 3000              # serve --migrate does both; --scheduler runs the jobs
tinkerex-sync device issue --email a@b.c     # prints user_id:/device_id:/device_token: as the rake task did
tinkerex-sync device list  --email a@b.c
tinkerex-sync stats [--brief]                # what bin/backup-db and bin/restore-db (maker repo) parse
tinkerex-sync routes                         # the 29 HTTP routes + /cable
tinkerex-sync doctor                         # config, schema presence, the Postgres pooler probe
tinkerex-sync gc retention    [--grace 3600] [--user N] [--dry-run]
tinkerex-sync gc reap-pending [--ttl-hours 24]   [--user N] [--dry-run]
tinkerex-sync gc reap-storage [--grace-hours 24] [--user N] [--dry-run]
```

## Environment

The **same names the Rails host read**, so the accessory's env block changes by zero lines:

| variable | meaning |
|---|---|
| `DATABASE_URL` (`postgres://…` or `sqlite:…`) else `SQLITE_DATABASE` | default `storage/production.sqlite3` |
| `STORAGE_BACKEND` = `local` \| `s3` | required; `memory` is refused |
| `CHUNK_LOCAL_DIR`, `CHUNK_PUBLIC_URL` | the local blob tier (default `tmp/chunk-store`; URLs from the request's own host unless set) |
| `CHUNK_BUCKET`, `CHUNK_ENDPOINT`, `CHUNK_REGION` (default `auto`), `CHUNK_ACCESS_KEY_ID`, `CHUNK_SECRET_ACCESS_KEY` | the s3 store, path-style, presigned SigV4 |
| `SECRET_KEY_BASE` | required; HMAC key of the local blob URLs — keep the Rails value so URLs in flight stay valid |
| `SYNC_ADMIN_TOKEN` | blank = `POST /v1/admin/libraries` answers 503, never a boot refusal |
| `SYNC_VERIFY_FINALIZE` | default on: finalize HEADs first-seen chunks |
| `RETENTION_POLICY` = `keep_all` \| `tiered` | default `keep_all` |
| `SYNC_SCHEDULER=1` (or `serve --scheduler`) | reap-pending hourly at :30, retention 03:15 UTC, reap-storage Sundays 04:15 UTC; off by default |
| `SYNC_DB_POOLER_CHECK` = `warn` (default) \| `refuse` \| `skip`; `DB_SKIP_POOLER_CHECK=1` | the Postgres statement-mode pooler probe at boot |
| `RUST_LOG` / `RAILS_LOG_LEVEL`, `SYNC_LOG_JSON=1` | logging |
| `BIND`, `PORT` | `serve` defaults `0.0.0.0:3000` |

`CABLE_ADAPTER` is read by nothing: one process, one in-memory hub, as the Rails host's `async`
adapter was.

## Storage conventions (plan §0.5 — what makes the swap reversible)

Every row this binary writes is an ordinary row to Rails, and vice versa:

- **The schema is the Rails schema**, DDL included (`src/schema/*.sql`), plus the two
  `schema_migrations` rows (`20260101000001`, `20260101000002`) and `ar_internal_metadata`
  (`environment`, `schema_sha1`). `migrate` adopts an existing Rails file after verifying both.
- **SQLite datetime text is Rails' text**: `YYYY-MM-DD HH:MM:SS` with six fractional digits only
  when the microseconds are nonzero; booleans are `0`/`1`; NULLs are bound with their column's
  type; integers are bound as `i64`. Measured in `src/db/README.md`.
- **JSON timestamps** are `%Y-%m-%dT%H:%M:%S.mmmZ`, truncated to milliseconds; `expires_at` is
  parsed leniently and an unparseable or non-string value means no expiry.
- **Mode defaults** 493 (dir) / 420 (file) / 511 (symlink); `updated_at` moves on every node write;
  `versions` has no `updated_at`; `versions.created_at` is the tiered policy's clock.
- **Tokens** are 32 random bytes, base64url without padding (43 chars), stored as SHA-256 hex.
- **Blob URLs** are `{base}/v1/chunks/blob/{user}/{hash}?exp=&sig=` with
  `sig = hex(HMAC-SHA256(SECRET_KEY_BASE, "user\nhash\nexp"))` — known-answer tested against Ruby's
  OpenSSL.
- **Per-user chunk keys** `chunks/<user_id>/<hash>` on both stores.

## Invariants the code makes structural (plan §5)

- A mutation allocates its changelog `seq` under the user row lock (`BEGIN IMMEDIATE` on SQLite,
  `FOR UPDATE` on Postgres) before any other write — `services::mutation::UserWrite::begin` is the
  only way to get the transaction. `tests/concurrency.rs` proves gapless allocation under contention.
- Every refcount write goes through `models::touch_refcounts`, which always moves `updated_at`.
- `gc::sweep_orphans` deletes compare-and-swap (`refcount <= 0` re-asserted in the DELETE) and the
  row before the bytes; `gc::prune_version` is claim-then-decrement under the user lock;
  `gc::referenced_version_ids` protects open conflicts' sides and live share links' versions.
- The two reapers keep deliberately different pending guards (`services/reapers.rs` explains).
- The read services cost a constant number of statements (`tests/query_budget.rs`).

Each of these has a mutation check on record in the commit history (the guard was broken, the
test went red, the guard was restored).

## Gates

```sh
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo deny check licenses sources        # permissive licences only; deny.toml
cargo test                               # SQLite; TEST_DATABASE_URL=postgres://… adds the Postgres leg
bin/conformance-rust                     # boots the binary on 3004 and runs the whole corpus
```

`bin/conformance-rust` last reported `18 runs, 284 assertions, 0 failures, 0 errors, 0 skips`
(2026-09-30), the same figure the Ruby host reports on a fresh database.

## The image

`Dockerfile.rust` (`SYNC_IMPL=rust bin/build-and-push`) keeps the Ruby image's paths, port, uid and
entrypoint guard. It has not been built on this branch's development box (no Docker there); its
size is to be measured on first build and recorded here beside the Ruby image's 422 MB.
