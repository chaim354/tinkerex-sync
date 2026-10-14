# The Rust Rewrite of the Sync Server — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: the maker repo's `.claude/commands/execute-plan.md`
> (batched by file, disjoint tasks in parallel, one capped full-depth review per task) overrides
> any generic subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking. Every guard this
> plan asks for is mutation-checked before it counts (CLAUDE.md §5).

**Status:** PLAN. 2026-09-30. Written against `tinkerex-sync@3c76ffc`, `tinkerex@main`,
`tinkerex-client@main`, all read directly, not from memory. Numbers below (line counts, endpoint
counts, test counts) were measured in those checkouts on this date.

**Goal:** Replace the Rails sync server (`app/` + `lib/` + `host/` in this repo) with a single
Rust binary that answers the **same 28 routes, byte-for-byte on the wire**, reads and writes the
**same database file and chunk volume** the deployed accessory uses today, and is swapped in as a
**deployment change, not a code change** to the maker app or the desktop client — the end state
`chaim354/tinkerex`'s Stage 5 design promised
(`docs/superpowers/specs/2026-08-23-stage-5-engine-leaves-the-process-design.md` §0 there).

**Architecture:** One Cargo crate, `crates/tinkerex-sync`, producing one binary with subcommands
(`serve`, `migrate`, `device`, `gc`, `stats`, `doctor`). axum over tokio for HTTP and the `/cable`
WebSocket; sqlx against **SQLite and Postgres** through one hand-written SQL layer that reproduces
Rails' storage conventions (the datetime text format, 0/1 booleans, the `schema_migrations`
rows) so a Rails-written database is readable by Rust and a Rust-written one by Rails — which is
what makes cutover reversible. Chunk bytes never touch the process except on the `local` store's
own signed blob endpoints, exactly as today. The corpus under `conformance/` is the grader; the
Ruby verifier stays as the instrument, deliberately, because a verifier written by the same hands
as the Rust server would share its misunderstandings (`conformance/README.md`, "Why this corpus
exists").

**Tech stack (all MIT/Apache-2.0/BSD, enforced by `cargo-deny`):** axum, tokio, tower-http,
serde/serde_json, sqlx (`sqlite` + `postgres`, rustls), aws-sdk-s3 (presigning, path-style),
sha2/hmac/subtle/hex/base64/rand, chrono, uuid, clap, tracing + tracing-subscriber, tungstenite
(tests only, to drive `/cable` the way `sync-client` does).

**Normative references:** `../tinkerex/docs/sync-protocol.md` (the wire), `conformance/README.md`
+ `conformance/scenarios/*.yml` (the recorded truth), this repo's `CLAUDE.md` §4 (the invariants
that each cost a real bug). Where this plan and a recorded scenario disagree, the scenario wins.

---

## 0. What was measured, and what it decides

| Fact (measured 2026-09-30) | Consequence for the plan |
|---|---|
| The engine is **~4,700 lines of Ruby** under `app/`+`lib/` (about 4,000 without the unported 682-line `FileLayer::Chunk` adapter; a large share is comments), plus `host/` at ~400. The corpus is 11 scenario files, ~2,500 lines, hitting all 26 drawn routes + the 2 host device routes. | The port is small. The corpus, not the Ruby tests, is the acceptance test; Ruby tests are read for **branches the corpus does not pin** (§3). |
| **Production is SQLite + `STORAGE_BACKEND=local`, one container**, as the `sync` Kamal accessory in `../tinkerex/config/deploy.yml` (`ghcr.io/chaim354/tinkerex-sync:latest`, volume `tinkerex_sync_storage:/rails/host/storage`, `CHUNK_LOCAL_DIR=/rails/host/storage/chunk-store`, `CABLE_ADAPTER=async`, `SECRET_KEY_BASE`, `SYNC_ADMIN_TOKEN`). | Cutover = a new image behind the **same** accessory block. The first Rust image keeps the same paths, port, env names and `/up` so `deploy.yml` changes by zero lines. Postgres parity matters for the managed product, **not** for cutover (§6). |
| **The deployed host schedules no jobs.** `host/config/` has no `recurring.yml`/`queue.yml`; nothing enqueues `Sync::RetentionJob`, `Sync::ChunkReaperJob` or `Sync::PendingCommitReaperJob`. `RETENTION_POLICY` defaults to `keep_all`. | GC/retention/reapers are ported for **parity of mechanism**, but *enabling* them in production is a behaviour change with its own dry-run step (§7). Nothing about cutover depends on them. |
| `Sync::Hooks` has **no subscriber** on the standalone host; `FileLayer::Chunk` (682 lines) is an in-process Ruby door the maker app no longer loads (`LIBRARY_BACKEND=chunk` is refused there); `Sync::V1::CapabilityGate` always answers "available" on a bare host. | None of the three is ported. The 501 shape becomes unreachable, which the wire spec §7 explicitly permits. |
| The only credential is `SHA256(token)` hex against `devices.token_digest`; tokens are `urlsafe_base64(32)` (43 chars). The `local` blob URLs are `HMAC-SHA256(SECRET_KEY_BASE, "user\nhash\nexp")` hex in `?exp=&sig=`. | Both are reproduced exactly, with the **same env values**, so every existing device token and every presigned URL in flight stays valid across the swap. |
| **Measured 2026-09-30 (0.2):** the Ruby host refuses any `/cable` connection with no `Origin` header — which is what `sync-client::watch_library` sends — with a 404 ("Request origin not allowed"), so the deployed daemon has only ever polled. With an allowed origin, the client's identifier `{"channel":"LibraryChannel"}` is `welcome`d and never confirmed (the class is `Sync::LibraryChannel`); the namespaced spelling is confirmed; a bad token gets `{"type":"disconnect","reason":"unauthorized","reconnect":false}` then close; pings carry a unix timestamp every 3 s. | The Rust `/cable` checks no origin and accepts **both** spellings (`crates/tinkerex-sync/src/http/cable.rs`, `tests/cable.rs` drives it with the client's exact frames). Cutover therefore enables the nudge for the first time; §7.3 says so. |
| `../tinkerex-client`'s server-backed suites enrol via `POST /v1/test/users` + `POST /v1/devices/login` — **maker-app routes the standalone host has never served**, so those suites cannot currently run against this server despite that repo's CLAUDE.md saying they do. | A cross-repo task gives those suites an enrolment path the sync server actually has (§8). Not a cutover blocker: the deployed client authenticates with an already-issued token. |
| `../tinkerex/bin/restore-db sync` verifies a restore by `docker exec … bin/rails runner`; `bin/sync-server` boots `host/` with `bin/rails`; both parse `device_token:` out of `sync:device:issue`'s output. | The binary ships `stats` and `device issue` subcommands with **identical output lines**, and the two maker scripts switch to it in one PR (§8). |
| `next_seq!` (the `FOR UPDATE` row lock taken **first** in every mutating transaction), refcounts only through `Gc.touch_refcounts!`, compare-and-swap in `sweep_orphans!`, claim-then-decrement in `prune_version!`, `share_links` protecting versions from retention — CLAUDE.md §4b, each a recorded data-loss bug. | Each becomes a **structural** property in Rust (a mutation API that cannot run a write before the lock; a refcount function that cannot skip `updated_at`) plus a test that fails when the structure is bypassed (§4 task 2.1, §5). |

---

## 1. Decisions (settled here so no task re-litigates them)

- **D1. Where the code lives:** in *this* repository, at `crates/tinkerex-sync`, with a workspace
  `Cargo.toml` at the root beside the Ruby tree until Phase 6 deletes the Ruby. Every sibling
  (`../tinkerex/bin/sync-server`, both CLAUDE.md files, the Kamal image name, the corpus) already
  points here; a new repo would move all of that for nothing. Unlike `tinkerex-client`, this repo
  gets a real workspace — there is one deployable, so `cargo test` at the root must mean something.
- **D2. Same schema, same conventions, in place.** The Rust server opens the Rails-created
  `production.sqlite3` as is. It writes datetimes as the text Rails writes on SQLite
  (`YYYY-MM-DD HH:MM:SS.ffffff`, UTC, no zone suffix), booleans as 0/1, and never touches
  `schema_migrations`/`ar_internal_metadata` except to *add* the two Rails versions on a fresh
  database — so the Ruby image can still boot on a Rust-written file (rollback, §7). Renaming
  tables or columns is out of scope until the Ruby is gone.
- **D3. Both databases from day one, SQLite first.** The Ruby engine is adapter-agnostic by rule
  (CLAUDE.md §5) and the managed product needs Postgres. The SQL layer is hand-written text with
  a tiny dialect seam (placeholders, `FOR UPDATE`, `BEGIN IMMEDIATE`, timestamp encoding), not an
  ORM: the queries are few, and the two hardest (`WITH RECURSIVE` search, the sliced `IN (...)`
  batch loads) already exist as portable SQL in Ruby. Phase 0's spike proves the seam on both
  drivers before anything is built on it.
- **D4. Two chunk stores, not three.** `local` (HMAC-signed blob endpoints, atomic tmp+rename
  writes, mtime for reaper age) and `s3` (SigV4 presigning, path-style, custom endpoint,
  `head/put/delete/list_objects_v2`). The Ruby `memory` store exists only to presign to a
  dev-only Rails route; Rust tests use `local` under a temp dir, which is also what CI and
  production run.
- **D5. The Ruby verifier and recorder stay.** After Phase 6 the Gemfile shrinks to what
  `test/conformance_test.rb` and `bin/conformance-record` need. A Rust corpus runner is *not* on
  this plan: the corpus's own argument is that the grader must not share the implementation's
  assumptions.
- **D6. The corpus is extended against the Ruby reference *before* the port** (§3), so every
  branch the Ruby tests pin and the corpus does not is recorded from the server that has it. After
  cutover the Rust server is the recording reference; any behaviour change re-records and
  re-reviews per `conformance/README.md`.
- **D7. Cutover is a container swap behind an unchanged accessory block**, with a backup taken
  first and a rollback rehearsed first (§7). `:latest` keeps pointing at whichever image is
  current; the previous Ruby image's revision tag is the rollback target.
- **D8. Zero maker-app *application* changes.** Only two dev/ops scripts there change
  (`bin/sync-server`, `bin/restore-db`), plus docs. If a task finds itself editing
  `../tinkerex/app/`, the wire is wrong, not the maker app.

---

## 2. What must hold on the wire (the contract, in one place)

The 28 routes, grouped the way the wire spec groups them. Status and body shapes are pinned by the
scenario named; unpinned rows are the §3 work.

| Route | Pinned by | Notes the port must not lose |
|---|---|---|
| `GET /v1/devices/whoami` → `{user_id, device_id, head_seq}` | 01 | `head_seq` is `users.head_seq`. |
| `POST /v1/devices {name}` → 201 `{device_id, device_token}` | 01, 04, 07, 08 | `name` blank → `"device"`. Token shown once. |
| `POST /v1/commit` → `{commit_id, missing[], put_urls{}}` | 02–10 | 64-lowercase-hex hash rule at the door; `manifest_id = sha256(hex hashes joined)`; re-`begin` is an unconditional upsert of the pending row; `size`/`mode`/`mtime` coerce, never 400. >100,000 entries → 422. |
| `POST /v1/commit/:id/finalize` → `{version_id, seq}` | 02–10 | verify-bytes-landed ON by default (`SYNC_VERIFY_FINALIZE=1`), `422 {error: chunks_missing, missing}`; kind conflict → 409; conflict detection incl. the **same-device fast-forward** exception; identical response shape for put and conflict; a body key `verify` (the maker app sends one) is **ignored**. |
| `GET /v1/changes` | 03, 07 | `since` `.to_i`, `limit` clamp 1..2000 default 500; `version`/`manifest` present only for `put` with a resolvable version; `oldest_seq` = MIN(seq) or **`head_seq + 1`** on an empty table. |
| `GET /v1/tree` | 06 | `after_id` is the integer PK cursor; clamp 1..5000 default 1000; present nodes only; `next_after_id` null on an empty page; symlink carries base64 `symlink_target`. |
| `GET /v1/search` | 06 | blank `q` → `{results: []}`; recursive CTE, `LOWER(path) LIKE … ESCAPE '\'`, `ORDER BY path`, depth cap 4096, clamp 1..200, offset ≥ 0, `size` null for dirs. Ungated. |
| `POST /v1/nodes` (mkdir) → 201 `{node_id, seq}` | 03–06 | `node_id`/`name` required → 400; kind change → 409; cycle → 422 `"move would create a cycle"`; mode default 493; op `mkdir`. |
| `POST /v1/nodes/symlink` → 201 | 04, 06 | strict base64 target (invalid → 422); mode default 511; no cycle guard; op `symlink`. |
| `DELETE /v1/nodes/:id` → `{seq}` | 04, 05, 06, 08 | cascades over the **present** subtree, BFS under the lock, one seq + one `delete` entry per node, returns the last seq. |
| `POST /v1/nodes/:id/move` → `{seq}` | 04 | omitted vs explicit-null `new_parent_node_id` differ; `new_name` blank = no rename; cycle guard; no parent-existence check. |
| `GET /v1/nodes/:id/versions` | 04, 07 | newest first (`ORDER BY id DESC`), limit 200, `created_at` as `…T…Z` with 3 fractional digits. |
| `POST /v1/nodes/:id/restore {version_id}` → `{version_id, seq}` | 04 | new version reusing the old manifest, refcounts +1 via the one touch function, `device_id` **null**, clears a tombstone, op `put`. |
| `POST /v1/nodes/:id/resolve_conflict` | 04, 07 | `keep_version_id` → resolves **all** rows for the node; not a side → 422 `"version is not part of this conflict"`; `split: true` (Boolean-cast) → one sibling per divergent incoming, name `"<base> (conflict from <device> <YYYY-MM-DD HHMM>)<ext>"` in UTC, `{split_node_id, split_node_ids, seq}`. |
| `GET /v1/conflicts` | 07 | one row per `(node, incoming)`; `device_name` falls back to `"another device"`. |
| `GET /v1/trash` | 05 | `deleted = true` ordered `updated_at DESC, name ASC`; `deleted_at` **is** `updated_at`; sizes batch-loaded. |
| `POST /v1/trash/:id/restore {to_root?}` | 05 | already live → 200 with `seq: null`; orphan → 409 `parent_deleted` unless `to_root`, which nulls the parent; op `put` with the node's `current_version_id`. Keep the caller-supplied `to_root` (CLAUDE.md §4a). |
| `POST /v1/nodes/:id/lock` / `unlock`, `GET /v1/locks` | 08 | live node or 404 (identical for unknown and tombstoned); TTL 5 min; never steals; `by_me` per caller; `{released: bool}` honest. |
| `POST /v1/chunks/download {hashes}` | 09 | malformed and unowned hashes silently omitted; >10,000 → 422; URLs only for owned `(user, hash)`. |
| `POST /v1/share_links`, `DELETE /v1/share_links/:id` | 10 | version must belong to the caller (404 otherwise); raw token once; `expires_at` echoed as `…T00:00:00.000Z`; delete → 204. |
| `GET /v1/share/:token`, `POST /v1/share/:token/download` | 10 | **no bearer check at all**; dead token → 404 `not_found` for every reason; presigns against the owner's keyspace for exactly the frozen manifest. |
| `PUT`/`GET /v1/chunks/blob/:user_id/:hash` | 02–10 | HMAC in the query; 403 on tamper/expiry, 404 when the store is not `local`; PUT ≤ 64 MiB else 413 text; GET `application/octet-stream`, `inline`. |
| `POST /v1/admin/libraries {email, name?}` | 11 | unset `SYNC_ADMIN_TOKEN` → 503 `admin_provisioning_disabled`; constant-time compare; device tokens refused; repeat email → 409 `email_taken`. |
| `GET /up` | (device journey, host suite) | `text/plain` `ok` after a real `SELECT count(*) FROM users`; 503 otherwise. |
| `/cable` | (none — §4 task 3.1 test) | Action Cable framing: `welcome`, `confirm_subscription`, 3 s `ping`, `{"identifier":…,"message":{"head_seq":N}}`; auth via `?token=`. |

Shared rules: `Authorization: Bearer <token>` (a header without the prefix is used verbatim as the
token); 401 `{"error":"unauthorized"}`; every not-found is exactly `{"error":"not_found"}`;
JSON responses are `application/json`; every authenticated request stamps `devices.last_seen_at`.

---

## 3. Phase 0 — Pin and de-risk before writing the server

Each task here is against the **Ruby** server (`host/`, `STORAGE_BACKEND=local`, port 3003, the
CI job's own boot recipe) and produces either a recorded scenario or a written decision.

- [x] **0.1 Extend the corpus to the branches the Ruby suite pins and the corpus does not.** Author
  the requests by hand, record with `bin/conformance-record`, review every `$type` per the
  README. One new file per theme, continuing the numbering:
  - `12-edge-cases.yml`: `POST /v1/nodes` missing `node_id` (400); `POST /v1/commit` with a
    malformed hash (422 message), with a null-hash manifest entry, with missing `name` (422
    validation message); mkdir onto an existing **file** (409); symlink with a blank target and
    with invalid base64; `move` with an omitted vs a null `new_parent_node_id`; `changes` with
    garbage `since`/`limit`; `search` with `limit=999&offset=-3`; `resolve_conflict` with
    `split: "1"`; finalize called twice (second → 404); re-`begin` the same `commit_id` with a
    different manifest; `DELETE` an already-tombstoned node (a second `delete` entry is minted);
    `versions` of a directory; a commit that revives a tombstoned node; a 401 on a device route
    with no header and with a garbage token.
  - `13-conflicts-fast-forward.yml`: the same-device exception (device A commits v3 based on v1
    while current is A's own v2 → `put`, no conflict row) and a restore-then-commit (the restored
    version has `device_id` null, so a stale base from any device **is** a conflict).
  - `14-tenancy.yml`: provision a second user via the admin route, then prove every node-scoped
    route answers 404 for the other tenant's ids, `chunks/download` mints nothing for the other
    tenant's hash, and `share_links` create/delete refuse the other tenant's version and link.
  - `15-share-links-edge.yml`: a malformed `expires_at` (record what Rails actually does —
    spec §13 says it is unverified), a link for a version on a tombstoned node, `download` for an
    expired link.
  - `16-blob-tier.yml`: tampered `sig` (403), expired `exp` (403), a GET for a never-uploaded
    hash under a valid signature (404), a PUT over 64 MiB is **not** recorded (the corpus cannot
    carry that body) — it becomes a Rust unit test instead.
  Update `test/conformance_test.rb`'s coverage expectations if a route count changes (it derives
  the list from the drawer, so it should not). Verified output must be `N runs, 0 skips` in CI.
  **Done 2026-09-30:** five files recorded against the Ruby host, reviewed per the README (client-chosen
  ids tightened to literals, every `seq` loosened, presigned URLs to `$type`), then verified from a fresh
  database and user on BOTH servers: `18 runs, 284 assertions, 0 failures, 0 skips` each. Findings: a
  mkdir under a FILE parent is accepted (pinned, not judged); a numeric `expires_at` was stored as a raw
  integer and 500'd every redeem (fixed in the Ruby controller first, then recorded); a malformed blob
  hash answers Rails' own dev error page (only the status is pinned); the blob PUT never verifies content.
- [x] **0.2 Probe the cable identifier.** With the Ruby host running, open a WebSocket to
  `/cable?token=…` and send `{"command":"subscribe","identifier":"{\"channel\":\"LibraryChannel\"}"}`,
  then commit a file. Record whether a `confirm_subscription` and a `{head_seq}` frame arrive, or
  a `reject_subscription`. Write the answer into task 3.1's test as the expected *current* behaviour
  and file a client issue in `tinkerex-client` if the subscription is rejected today.
  **Done 2026-09-30:** see §0's cable row. The connection itself is rejected (no Origin), so the daemon has
  polled all along; the client issue is §8.2's to file alongside the enrolment change.
- [x] **0.3 The SQL-layer spike, on a copy of a real database.** Take `bin/backup-db sync` from
  the maker repo (or a `test/dummy` database after the corpus has run) and, in a throwaway crate,
  prove on **both** sqlx drivers: `$1` placeholders; reading Rails' datetime text into
  `chrono::NaiveDateTime` and writing it back **byte-identical**; booleans; `BLOB`
  `symlink_target`; `BEGIN IMMEDIATE` + `busy_timeout` on SQLite and `SELECT … FOR UPDATE` on
  Postgres inside one transaction; the recursive-CTE search verbatim; a 5,000-bind `IN (...)`.
  Read `PRAGMA journal_mode`, `synchronous`, `foreign_keys` off the real file and record what the
  Rust connection must set. The spike's findings become `crates/tinkerex-sync/src/db/README.md`.
  If any of this fails on sqlx, the fallback is diesel's `MultiConnection` — decide here, once.
- [x] **0.4 Runners.** `charless-MBP-maker-mac` already has rustup (it builds `tinkerex-client`);
  update `ci/runners/setup-macos.sh`'s "does not install Rust" note. Decide whether to register a
  Linux runner (the maker repo's `ops/ci-runner-stack.yml` containers) against this repo for the
  Postgres leg; if not, the Postgres leg is a documented manual gate until Phase 6 (§6).
  **Decided 2026-09-30:** no Linux runner for now; the note is updated and the script refuses to
  register a box without `cargo`. The Postgres leg (`tests/concurrency.rs`, `TEST_DATABASE_URL`)
  prints that it did not run when unset, and `ci.yml`'s `rust-check` job says so in its comment.
- [x] **0.5 Write down the storage conventions** (D2) as a checklist in the crate README
  (`crates/tinkerex-sync/README.md`, with the measurements in `src/db/README.md`):
  timestamp format per dialect, JSON time format (`%Y-%m-%dT%H:%M:%S%.3fZ`), mode defaults
  (493/420/511), `updated_at` maintained on every node write, `versions` has no `updated_at`,
  `schema_migrations` versions `20260101000001`/`20260101000002`, `ar_internal_metadata`
  `environment=production`.

---

## 4. Phases 1–3 — Build the server, graded corpus file by corpus file

Milestone order **is** corpus order: a phase is done when `test/conformance_test.rb` passes through
that file against the Rust binary with `0 skips`, run from the repo root with
`SYNC_SERVER_URL=http://127.0.0.1:3004 SYNC_DEVICE_TOKEN=<issued by the Rust binary>`.

### Phase 1 — Skeleton, auth, the read side (through `01-enrolment.yml`)

- [x] **1.1 Crate scaffold.** *(`deny.toml` landed 2026-09-30 and was mutation-checked with a GPL path crate: red; `rustfmt.toml` is the default)* `Cargo.toml` workspace at the root; `crates/tinkerex-sync` (lib +
  bin); `rustfmt.toml`, `clippy` at `-D warnings`, `deny.toml` allowing MIT/Apache-2.0/BSD/ISC/
  Zlib/Unicode only (mutation-check: add a GPL crate to a scratch branch and watch `cargo deny`
  go red). `tracing` JSON to stdout (the accessory logs to stdout).
- [x] **1.2 Config.** One `Config` from the **same env names** the Ruby host reads:
  `STORAGE_BACKEND` (`local`|`s3`, no default in production — refuse to boot without it, matching
  `host/config/environments/production.rb`), `CHUNK_LOCAL_DIR`, `CHUNK_PUBLIC_URL`,
  `CHUNK_BUCKET`/`CHUNK_ENDPOINT`/`CHUNK_REGION`/`CHUNK_ACCESS_KEY_ID`/`CHUNK_SECRET_ACCESS_KEY`,
  `SECRET_KEY_BASE`, `SYNC_ADMIN_TOKEN` (blank = the door answers 503, never a boot refusal),
  `SYNC_VERIFY_FINALIZE` (default on), `RETENTION_POLICY` (`keep_all`|`tiered`), `DATABASE_URL`
  (Postgres) or `SQLITE_DATABASE` (default `storage/production.sqlite3`), `PORT`/bind,
  `RAILS_LOG_LEVEL`→ log level. `CABLE_ADAPTER` is read and ignored (one process, in-memory hub).
- [x] **1.3 Database layer** per the 0.3 spike: `Db` enum over `SqlitePool`/`PgPool`; a `Dialect`
  with placeholder, lock-clause and time-encoding methods; `Tx` wrapper; a `DbTime` newtype.
  `migrate` subcommand: fresh file → create the Rails-shaped schema (translated from
  `host/db/schema.rb`, indexes and FKs included) **and** insert the two `schema_migrations` rows +
  `ar_internal_metadata`; existing Rails file → verify the eight engine tables + three host tables
  exist and record a `_sqlx_migrations` baseline; later Rust migrations apply after it. `serve`
  runs `migrate` first only when told (`--migrate`, which the Docker entrypoint passes; `stats`
  and `device` never migrate), matching `host/bin/docker-entrypoint`'s guard.
- [x] **1.4 Auth + host routes.** Bearer extraction exactly as `Sync::V1::Authentication`;
  `Device` lookup by SHA-256 hex; `last_seen_at` stamp; `GET /up` with the real count;
  `GET /v1/devices/whoami`; `POST /v1/devices`; `device issue --email --name` and `device list`
  subcommands printing the **same lines** `host/lib/tasks/devices.rake` prints (`user_id:`,
  `device_id:`, `device_token:` — the maker CI parses them). Token minting: 32 random bytes,
  base64url unpadded.
- [x] **1.5 Error envelope.** One `ApiError` → `{ "error": … }` with the five shapes of
  `Sync::V1::BaseController` (404 always `not_found`; 400/422/409 carry the message); a JSON body
  that fails to parse → 400 (Rails' behaviour); unknown body keys ignored.
- [x] **1.6 The read services** *(guard: `tests/query_budget.rs`, mutation-checked with a per-row `Node::find` in `tree` — 6 vs 44 statements, red)*, each a bounded number of queries: `tree`, `changes`, `search`,
  `versions`, `conflicts` (list), `locks` (list), `trash` (list), with the batched
  `load_manifests`/`load_version_sizes` helpers. Guard: a test that counts sqlx statements via a
  `tracing` layer and asserts the count is **constant in N** (mutation-check by replacing one
  batch load with a per-row query and watching it fail).
- [x] **Gate:** `01-enrolment.yml` green; `cargo test` green on SQLite; `deny`/`clippy`/`fmt`
  green.

### Phase 2 — The write side, in corpus order (`02` through `11`)

- [x] **2.1 The mutation primitive.** `Mutation::run(user_id, |tx, seq| …)`: opens the
  transaction, takes the user row lock and allocates `seq` **before** handing control to the
  closure, stamps `updated_seq`/`updated_at`, appends exactly one changelog row. The closure
  cannot write before the lock because it never sees the transaction without the seq. Port the
  concurrent-seq property (`test/services/sync/concurrent_seq_test.rb`): 16 tasks × 25
  allocations on separate connections → exactly `1..400`, gapless; then the same through real
  begin+finalize. Runs on SQLite always, on Postgres when `TEST_DATABASE_URL` is set.
- [x] **2.2 Chunk store trait + `local` store** *(tamper/expiry/never-uploaded are pinned by `16-blob-tier.yml`; the 413 oversize case by `tests/limits.rs`)* (`presign_put`/`presign_get`/`exists`/`put`/
  `last_modified`/`list`/`delete`; key `chunks/<user>/<hash>`; HMAC scheme byte-identical to
  `Sync::Storage::LocalChunkStore`; public base = `CHUNK_PUBLIC_URL` else the request's
  scheme+host — honour `X-Forwarded-Proto`/`Host` behind kamal-proxy). Blob endpoints with the
  64 MiB body limit, atomic writes, constant-time signature compare. Unit tests: tamper, expiry,
  oversize (413 text), non-local backend (404), non-UTF-8 round trip.
- [x] **2.3 `commit` begin/finalize** per §2, including the verify HEAD, `ChunksMissing`, kind
  conflict, the conflict rule and its same-device exception, N-way conflict rows keyed by
  incoming version, the manifest/chunk upserts, and the one `touch_refcounts` function that
  always moves `updated_at`. → `02-commit.yml`.
- [x] **2.4 mkdir / symlink / move / delete(cascade)**, cycle and kind guards, `changes` for real.
  → `03-changes.yml`, `04-nodes.yml`.
- [x] **2.5 trash list/restore** with the caller-supplied `to_root`. → `05-trash.yml`.
- [x] **2.6 tree + search** against a mutated tree. → `06-tree-search.yml`.
- [x] **2.7 conflicts keep/split, restore-to-version.** → `07-conflicts.yml`.
- [x] **2.8 locks.** *(expiry: `tests/limits.rs`, with an explicit clock — held at TTL−1 s, taken over at TTL+1 s, the old holder cannot release the new lock)* → `08-locks.yml`. Plus a unit test for expiry (advance a mocked clock).
- [x] **2.9 chunks/download.** → `09-chunks.yml`.
- [x] **2.10 share links + anonymous redeem.** → `10-share-links.yml`.
- [x] **2.11 admin provisioning.** → `11-admin.yml`, then the §3 files `12`–`16`.
- [ ] **Gate:** the whole corpus, `N runs, 0 failures, 0 skips` *(done once per server, 18/284)*, twice in a row from two fresh
  users on one database *(needs a wipe between runs: `11-admin.yml` and `14-tenancy.yml` provision fixed emails)* (proves nothing leaks between runs), and once against a **copy of the
  production database** with a freshly issued user (proves the real schema and real rows).

### Phase 3 — Everything the corpus cannot see

- [x] **3.1 `/cable`.** axum WebSocket; `?token=` auth (reject → `{"type":"disconnect",
  "reason":"unauthorized","reconnect":false}` then close); `welcome`; `ping` every 3 s with the
  unix timestamp; `subscribe` for identifier `{"channel":"LibraryChannel"}` **and**
  `{"channel":"Sync::LibraryChannel"}` → `confirm_subscription`; per-user broadcast hub; one
  `{head_seq}` per **request** (the cascade and the split broadcast once, with the last seq, as
  the controllers do). Test: drive it with tungstenite exactly as `sync-client::watch_library`
  does (copy the frames, note the source), commit, assert the nudge arrives within a second.
- [x] **3.2 `s3` store** with aws-sdk-s3: path-style, custom endpoint, `region=auto`, PUT 900 s /
  GET 3600 s presigns, paginated list, idempotent delete. Test against a MinIO/SeaweedFS container
  where Docker exists; otherwise assert the **wire** — the signed URL's canonical request — not a
  round trip through the SDK (CLAUDE.md §5's `FakeS3` lesson).
  **2026-09-30:** `src/store/s3.rs`; the wire tests pin path-style host + key, the SigV4 query
  parameters, determinism, and that the secret and the user are in the signature. The bucket round
  trip turned out not to need Docker: `tests/s3_roundtrip.rs` runs against any S3 endpoint named by
  `TEST_S3_ENDPOINT` (+ bucket and keys) and prints `NOT RUN` otherwise, and it passed against a
  SeaweedFS 4.48 binary on the development box — the store's verbs, a presigned PUT and GET (an
  expired presign refused with 403 by the bucket), and a whole commit through the HTTP server
  whose finalize HEADs the bucket, refuses before the upload, and accepts after it. Still not in CI
  (no bucket on the runner); the README names the knobs.
- [x] **3.3 GC and retention.** `RetentionPolicy` (`keep_all`, `tiered` with the `<24h` tier
  keyed by `version_id`), `prune_version` claim-then-decrement, `sweep_orphans` compare-and-swap
  with the grace window on `updated_at`, `apply_retention` protecting open conflicts' sides and
  **live share links' versions**, `prune_changelog`. Port `gc_test.rb`'s cases, especially: the
  share-link line deleted → test red; the CAS removed → a concurrent re-reference loses its
  bytes → test red. `gc retention [--grace]` subcommand.
- [x] **3.4 The two reapers.** `gc reap-pending` (expired rows, committed ∪ live-pending guards,
  storage-age guard, rows destroyed on every path) and `gc reap-storage` (list-based, 24 h
  grace, **all** pending rows protect, no age filter). Port the divergence test that keeps the two
  guards deliberately different. Both take `--dry-run` and `--user`.
- [x] **3.5 Scheduler.** *(wall-clock: reap-pending hourly at :30, retention 03:15 UTC, reap-storage Sundays 04:15 UTC)* `serve --scheduler` runs reap-pending hourly, reap-storage weekly,
  retention nightly, in-process, with a single-flight guard (and a Postgres advisory lock when the
  pool is Postgres). Off by default; see §7 for when it turns on.
- [x] **3.6 `doctor`.** The Postgres pooler probe from `lib/sync/postgres_pooler_check.rb`
  (`pg_backend_pid` + advisory lock across two statements) as a subcommand and as an optional
  boot refusal (`SYNC_DB_POOLER_CHECK=refuse`), off by default — the same "deliberate switch"
  posture `docs/SYNC_SERVER.md` records.
- [x] **3.7 `stats`.** Prints the counts `../tinkerex/bin/backup-db` and `bin/restore-db` want
  (`users`, `devices`, `nodes`, `versions`, `chunks`, `manifest_chunks`, `changelog_entries`) in
  the `<label>  <count>` shape they parse.
- [x] **3.8 Operational shape.** Graceful shutdown on SIGTERM (finish in-flight commits); request
  ids; per-route body limits — a 100,000-entry manifest is roughly 10 MiB of JSON, so
  `POST /v1/commit` gets 16 MiB, every other JSON route 1 MiB, the blob PUT 64 MiB (measure the
  100k case and record it); a per-request timeout; `Content-Type` `application/json`.
  **Measured 2026-09-30** (`tests/limits.rs`): 20,000 manifest entries serialize to ~2.0 MB and
  150,000 to 15.4 MB, so 100,000 is ~10.3 MB — inside the 16 MiB commit limit with room; a 64 MiB+1
  blob answers 413 `chunk too large`, an over-limit JSON body 413 `{"error":"body too large"}`.
  Request ids (`x-request-id`, generated or propagated) and a 120 s timeout (408) are layered in
  `http::router`; the websocket is added after the timeout layer and is exempt.
- [x] **3.9 The image.** Multi-stage Dockerfile (`rust:bookworm` → `debian:bookworm-slim` with
  `ca-certificates` and **`curl`**, which `bin/restore-db` execs inside the container); uid 1000;
  `WORKDIR /rails/host`; entrypoint runs `migrate` only when the command is `serve`; `EXPOSE 3000`;
  OCI revision label as `bin/build-and-push` sets it. Measured size recorded in the README beside
  the Ruby image's 422 MB.
  **2026-09-30:** `Dockerfile.rust` + `bin/docker-entrypoint-rust`; `SYNC_IMPL=rust bin/build-and-push`
  selects it (same tags and revision label as the Ruby image — tags since 2026-10-07: `:<sha>-ruby` /
  `:<sha>-rust`, cutover plan §2.1). **Written, not built** — the
  development box has no Docker; the first build on the Mac measures the size and fills the README.
- [x] **3.10 CI.** New jobs in `.github/workflows/ci.yml`: `rust-check` (fmt, clippy, deny,
  `cargo test`), `conformance-rust` (build, `migrate`, `device issue`, `serve` on 3004 with
  `SYNC_ADMIN_TOKEN=conformance-corpus-admin-token STORAGE_BACKEND=local`, wait on `/up`, run the
  verifier, parse the summary line for `0 skips` and nonzero runs exactly as the Ruby job does).
  The Ruby jobs keep running until Phase 6.
  **2026-09-30:** both jobs written (the second is `bin/conformance-rust`, which does all of that);
  every step was run by hand on the development box, none yet on the Mac runner — the first PR
  run is the proof.

---

## 5. Invariants, restated for the Rust code (what the reviews check)

Each line is CLAUDE.md §4's rule with its Rust form and its mutation check.

- **Seq first.** Only `Mutation::run` can produce a `seq`; every write path takes it from there.
  Mutation: call a node write outside `run` → the concurrent property test detects a duplicate or
  a gap under load.
- **Refcounts move `updated_at`.** One `touch_refcounts(tx, user, hashes, delta)`; no other code
  path writes `chunks.refcount`. Mutation: a raw `UPDATE chunks SET refcount = …` → the grace-window
  test sweeps a freshly re-referenced chunk.
- **Sweep is compare-and-swap; prune is claim-then-decrement.** Mutation: drop the
  `AND refcount <= 0` predicate → the race test loses bytes; decrement before the delete → the
  overlapping-retention test double-decrements.
- **Share links protect versions.** Mutation: drop the `share_links` read from
  `referenced_version_ids` → the retention test prunes a linked version.
- **Bytes stay out of the process** except the `local` blob tier. Guard: the body-limit layer is
  per-route (16 MiB for `/v1/commit`, 1 MiB elsewhere, 64 MiB only on the blob PUT); a test
  posts 32 MiB to `/v1/commit` and 2 MiB to `/v1/nodes` and gets 413 from both.
- **Keys are user-scoped.** `key_for(user, hash)` is the only key constructor and it refuses a hash
  that is not 64 lowercase hex. Mutation: pass `../x` → refused before any store call.
- **Timestamps round-trip Rails.** A fixture database written by Rails is read, mutated, and
  re-read by the Ruby host in the rollback rehearsal (§7). Mutation: change the SQLite time format
  to RFC 3339 → the trash ordering test (mixed Ruby- and Rust-written rows) fails.
- **Adapter-agnostic SQL.** No `pg_*`/`json_*`-style function in the hot path; both drivers run
  the same text. Guard: the Postgres leg of `cargo test` runs the same suite.

---

## 6. Postgres

Not on the cutover path (production is SQLite) but on the managed-product path and part of the
engine's contract. In scope for this plan:

- [x] `TEST_DATABASE_URL` runs the whole `cargo test` suite on Postgres 16, including the
  concurrent-seq property with 32×50 and the corpus (`conformance-rust-postgres` job) — on the
  Linux runner if 0.4 registers one, else a documented manual gate that Phase 6 must show green
  in its PR body.
  **Measured 2026-09-30 on Postgres 16.13 (the development box, not a runner):** `TEST_DATABASE_URL`
  switches every integration test's `TestServer` to Postgres (a fresh database per run — the test
  files use fixed emails) and the whole suite passed there: 44 unit, cable 5, concurrency 3 (the
  16×25 allocations and 8×10 commits gapless on `FOR UPDATE`), gc 36, limits 4, query_budget 1,
  routes 1. `CONFORMANCE_DATABASE_URL` points `bin/conformance-rust` at an empty Postgres database
  (it refuses one `migrate` merely adopts) and the sixteen-file corpus passed there too:
  `18 runs, 284 assertions, 0 failures, 0 skips`. Still a manual gate in CI until a Linux runner
  exists — the `rust-check` job's comment says so, and the leg prints `NOT RUN` rather than passing
  when the variable is unset.
- [x] The `FOR UPDATE`-first ordering is the one place SQLite cannot catch a regression (single
  writer); the Postgres property test is the proof, so it is required before any Postgres
  deployment ever happens. *(the same measured run; `BEGIN IMMEDIATE`'s removal was the SQLite-side
  mutation check, red)*
- [x] `doctor` + the optional boot refusal cover statement-mode poolers. *(3.6; the probe itself is
  exercised only by hand against a real pooler — none here)*

---

## 7. Cutover and rollback

Pre-conditions: Phase 2's three-way corpus gate, Phase 3 complete, `../tinkerex`'s
`bin/ci test-chunk-remote` green against the Rust binary (§8.1), the tinkerex-client server-backed
suites green against it (§8.2), `bin/build-and-push` published and the image's revision label read
back from a `docker inspect`.

> **Executed per `2026-10-07-rust-cutover.md`** (written the day #16 merged), which found three
> things this section assumed wrongly: the Rust image lacks the `sqlite3` the maker repo's backup
> and restore scripts run inside the deployment image (§8.3's claim below is corrected there); no
> device can reach the internal-only accessory today, so 7.3's device probes need a door first; and
> `bin/build-and-push` moves `:latest` on every build, so a rehearsal image needs a revision-only
> push. Each step here keeps its box; the figures land here when that plan's phases run.

- [x] **7.1 Rehearse rollback first, off the box.** Restore a fresh `bin/backup-db sync` archive
  into a throwaway volume (`bin/restore-db sync <archive> --into rehearsal --yes`), run the
  Rust image against it, run corpus files 02–10 with a fresh user, stop it, boot the **Ruby**
  image against the same volume, run 02–10 again with another fresh user, and read back the nodes
  the Rust run created through `GET /v1/tree`. Record both outputs in the cutover PR.
  **2026-10-07, per the cutover plan's §3, before any image was pushed** (the ghcr token had
  expired, so the Rust image reached the box by `docker save | docker load` and the Ruby image is
  the one running, `R = 4148fcd6`): archive `7 nodes, 3 versions`; Rust `Adopted`, whole corpus with
  a fresh user `18 runs, 284 assertions, 0 failures, 0 errors, 0 skips`, then `41 nodes, 38
  versions`; Ruby on the same volume `41 nodes, 38 versions`, authenticates both Rust-issued tokens
  (200), `/v1/tree` lists the 28 Rust-written nodes, corpus minus 11/14 with a Ruby-issued user
  `14 runs, 231 assertions, 1 failure` — the numeric `expires_at` case, which is `5d600bf`'s own fix
  and absent from `R` by construction — then `71 nodes, 72 versions`; Rust again `Adopted`,
  `71 nodes, 72 versions`, reads Ruby's rows with Ruby's token (200). A Ruby-written chunk hydrated
  through Rust: sha256 of the bytes equals the hash. Full figures: cutover plan §0.5.
- [x] **7.2 Backup the live accessory** (`bin/backup-db sync`), verify the archive's counts.
  **2026-10-07 18:07 UTC:** `tinkerex-sync-20261007T180753Z.tar.gz`, `integrity_check ok`, 7 nodes;
  live `7 nodes, 3 versions` by `bin/rails runner` on the Ruby host.
- [x] **7.3 Swap.** Retag: `:latest` → the Rust revision; `bin/kamal accessory reboot sync` from the
  maker repo (its `deploy.yml` is unchanged). Probes, in order: `/up` 200; `whoami` with an
  **existing** maker user's token (`users.sync_device_token` there — proves token compatibility on
  real credentials); a maker-app write journey (mkdir, upload, rename, delete, restore) through
  the web UI; a desktop client push/pull; the cable nudge observed in the daemon's log
  (`nudge:` lines absent, a pull triggered within a second of a commit). **This is the first time the
  deployed client's nudge works at all** (§0.2: the Ruby host refused its Origin-less connection), so
  the before-state is polling latency, and the cutover PR must say so.
  **2026-10-07, in two attempts.** The first retag of `:latest` (`imagetools create`) read back as
  the Rust digest for about a minute and then reverted at the registry's origin; the `reboot` that
  pulled inside that window re-created the RUBY container (blank description label, `Booting Puma`)
  while reporting success — caught by the first probe. A fresh `SYNC_IMPL=rust bin/build-and-push`
  with `:latest` enabled pushed a new index (`9409d6ce…`, tag `:38931307…-rust`, the same binary)
  that persisted at the origin; `docker pull` ON THE BOX confirmed `Downloaded newer image` before
  the second `reboot` (7 s, 18:22:47–54 UTC). Probes, in order: `tinkerex-sync (rust)` /
  `38931307…`; `Adopted`, listening; `/up` ok, `13 nodes, 4 versions` (7/3 plus the day's probe
  traffic), `doctor` clean; the maker app's journey through its own port (mkdir, two-phase upload,
  rename, read, delete, restore, read, cascading delete) `JOURNEY OK`, sha256 matching twice;
  `RemoteChangelogPullJob` ran at :24, zero `FileLayer::FetchError`; admin door 409 `email_taken`
  for an existing email, 401 for a wrong token; the Ruby-issued probe device's token `whoami` 200
  through the door; an Origin-less `/cable` upgrade through kamal-proxy **101** (Ruby: 404);
  **the nudge arrives in 6.6 / 5.2 / 8.0 ms** over three runs of the client's `nudge` example
  (Ruby, minutes earlier: `404 Not Found` on connect, no nudge, `Disconnected`, the 2 s poll);
  share link: create 201, anonymous redeem 200, download POST 200, presigned GET byte-exact.
  In-flight blob URLs: not run (none minted before the swap). Deploy record tinkerex#328.
- [x] **7.4 Watch for one week** with the scheduler **off**. Then `gc reap-pending --dry-run` and
  `gc reap-storage --dry-run` against production, read the lists, and only then enable
  `--scheduler` (retention stays `keep_all`; it prunes nothing and sweeps nothing).
  **2026-10-14:** the week and its three dry-runs (0 / 0 / 0) are the cutover plan's §0.5 entry
  "§5, the watch week"; D3 = the maker PR adding `SYNC_SCHEDULER: "1"`, merged at the week's end.
- [ ] **7.5 Rollback if needed:** retag `:latest` to the last Ruby revision, reboot the accessory.
  Safe because of D2; proven by 7.1. Rows written by Rust are ordinary rows to Rails.

Record the arc in the Kaneo record via the maker repo's `bin/log`, as every arc is.

---

## 8. Cross-repo work (each its own PR in its own repo)

- [x] **8.1 `tinkerex`: `bin/sync-server`** *(branch `claude/rust-sync-server` there, 2026-09-30: the Rust arm keeps its own database and chunk dir under `tmp/`, writes the same env file; driven for real — prepare, start, whoami, admin door 201; the script test gained a stubbed Rust-arm happy path, mutation-checked; `bin/ci test-chunk-remote` measured on the development box against the Rust binary: the journey file `10 runs, 126 assertions, 0 skips`, then the full suite `4263 runs, 20336 assertions, 14 failures, 2 errors, 32 skips` against `bin/ci test`'s `4263 runs, 20178 assertions, 14 failures, 2 errors, 56 skips` — identical run counts, the same sixteen failures on both legs and all of them this box's (root can read "unreadable" directories, no preview renderers), 24 fewer skips because the chunk_remote-gated tests ran)* gains `SYNC_IMPL=rust|ruby` (default `ruby` until
  cutover, then `rust`, then the switch is removed with the Ruby): `prepare` = `cargo build
  --release --manifest-path ../tinkerex-sync/Cargo.toml` (or `TINKEREX_SYNC_BIN`), `migrate`,
  `device issue`; `start` = `serve --bind 127.0.0.1 --port $SYNC_PORT` with
  `STORAGE_BACKEND=local`. The `unset_inherited_bundler_env` trap does not apply to a Rust
  child, but leave the function for the Ruby arm until it is deleted. `config/ci.rb`'s
  `test-chunk-remote` gate must report the **same run count** as the other two legs (§15 there).
- [x] **8.2 `tinkerex-client`: enrolment against the real server.** *(branch `claude/sync-server-enrolment` there, 2026-09-30: `SYNC_IT_ADMIN_TOKEN` switches `enroll` to `POST /v1/admin/libraries`, a second device joins via `create_device`; measured against the Rust binary with `SYNC_VERIFY_FINALIZE=0`: integration 25, fault_injection 11, two_device_e2e 9, parallel_hydration 8, offline_availability 5, adversarial_sync/concurrency_load/multifiletype_conformance 4 each, scale/reconcile_sweep 1 each, all passing; the password-login test prints SKIPPED there; that repo's CLAUDE.md §5 now says so)* The server-backed suites and
  examples call `enroll` → `/v1/test/users` + `/v1/devices/login`, which the sync server does not
  have. Add `SYNC_IT_ADMIN_TOKEN`: when set, `two_devices()` provisions through
  `POST /v1/admin/libraries` and uses the returned token; `RegisterResponse.head_seq` is then read
  from `whoami`. Keep `device_login` for the maker-app-shaped server. Run `integration`,
  `adversarial_sync`, `concurrency_load`, `two_device_e2e`, `scale`, `fault_injection` against the
  Rust binary and record the counts in that repo's CLAUDE.md §5 table, which currently says these
  run against `tinkerex-sync` — a claim this plan found false.
- [x] **8.3 `tinkerex`: `bin/restore-db`** — the `sync` arm's `bin/rails runner 'puts …'` becomes
  `docker exec … tinkerex-sync stats`; ~~`ops/backup-db.sh` needs nothing (it reads the volume with
  its own sqlite3)~~ — **wrong, found 2026-10-07:** it runs `sqlite3` inside the *deployment's own
  image* (`docker run … "$image" sh -c "$WORKER"`), as do `bin/restore-db`'s helper and its
  `--into` verify, and `Dockerfile.rust` installs no `sqlite3`. The cutover plan's §2.1 adds it
  before the image is ever built. `test/bin_sync_server_test.rb` there covers the script change.
  **2026-09-30 (same maker branch as 8.1):** the arm probes the container for the binary and reads
  `stats --brief`, falling back to `bin/rails runner` on the Ruby image, so a rolled-back container
  verifies the same way as a rolled-forward one. Shell, not unit-tested — it is an ssh + docker exec
  line the way the rest of that script is (maker CLAUDE.md §14i's "nothing in `bin/ci` can go red").
- [x] **8.4 Docs.** `../tinkerex/docs/sync-protocol.md`: endpoint count and the "not yet built"
  Rust row in §2's table; `../tinkerex/CLAUDE.md` §3/§14j (still describes this repo as a Rails
  engine, and §14j's "device auth is duplicated by structural necessity" now names a Rust
  function); `../tinkerex-client/CLAUDE.md` §7 and its §5 claim about the integration suites.
  **2026-09-30:** all three edited on the branches 8.1 and 8.2 name — the protocol doc's intro and
  table row (the embedded form's retirement noted alongside), the maker §3 row and the §14j bullet
  (`crates/tinkerex-sync/src/auth.rs`'s `authenticate`), and the client §5 table of measured suite
  counts plus the two env knobs, with §7's row noting the `/cable` change.

---

## 9. Phase 6 — Decommission the Ruby

Only after §7.4's week and a rollback window the operator is comfortable with.

- [x] Delete `app/`, `lib/`, `host/`, `test/` (except `test/conformance_test.rb` and
  `test/test_helper.rb`'s minimal replacement), `db/`, `tinkerex-sync.gemspec`, `Rakefile`'s
  engine tasks, the Ruby `Dockerfile` stages; shrink the `Gemfile` to `json_schemer` + `minitest`
  (+ `psych`) for the verifier and recorder. `test/conformance_test.rb`'s route-coverage check
  drew `Sync.draw_v1_routes`; replace it with a checked-in route list the binary prints
  (`tinkerex-sync routes`) and a test that the printed list matches the checked-in one, so the
  "every route is exercised" guard keeps a source that cannot go vacuous.
  **2026-10-14** (branch `claude/e3-decommission`): 159 tracked files and 11,132 lines deleted —
  `app/` 50, `lib/` 7, `host/` 36, `db/` 1, `test/` 61, the gemspec, the Ruby `Dockerfile`, and
  `config/deploy.yml` + `.kamal/secrets` (the Ruby host's standalone kamal *service*, which built
  the deleted `Dockerfile` and collided with the accessory). `test/` keeps the verifier, a plain
  Minitest helper, and two tests of tooling that stays — the matcher's (`conformance_runner_test.rb`)
  and `bin/build-and-push`'s; the Gemfile is `rake`, `minitest`, `json_schemer` (no `psych`: the
  bundle has always used Ruby's default psych, and naming it would add a native gem build). The
  route list is `conformance/routes.txt`, 30 lines — the binary's 28 `/v1` routes plus `GET /up`
  and `GET /cable` (the Ruby drawer's 26 are among them, compared line for line) — held to
  `tinkerex-sync routes` byte for byte by `tests/routes.rs`; the verifier refuses an empty list,
  and names `/up` and `/cable` as coverage exceptions with reasons. Corpus against the binary:
  `18 runs, 284 assertions, 0 failures, 0 errors, 0 skips`. Both guards mutation-checked (the
  commit body has the red lines). Postgres legs not re-run (no Postgres on the Mac).
- [x] Remove the Ruby CI jobs; `conformance-rust` becomes `conformance`. **2026-10-14:** `test` and
  the Ruby `conformance` are gone; the renamed job runs `bundle exec rake test` (the tooling's own
  tests, which only the deleted `test` job ran) and then `bin/conformance` (was
  `bin/conformance-rust`, now a shim for one release).
- [x] Rewrite this repo's `CLAUDE.md`: §0–§3 for the binary; §4 keeps every rule with its Rust
  form (§5 above) and drops §4a/§4c (the in-process adapter and the engine-structure rules, which
  have no Rust counterpart) with a one-line note of where they went; §7 (the corpus) unchanged in
  substance; §8 for `cargo`/`docker`/`bin/build-and-push`. **2026-10-14.** 4a's four server-side
  rules (the device API's `to_root`, no destination-vacant check, idempotent live undelete, name
  checked for presence only) are kept in a new §4d beside this plan's §5; 4c's two general guard
  lessons moved to §5; §6 is now the image and `bin/build-and-push`.
- [x] `README.md`: the binary, its subcommands, the env, the volume, the two stores, the
  measured image size and corpus run line. **2026-10-14**, plus how the maker app and devices
  reach it.
- [x] `docs/SYNC_SERVER.md`: mark HISTORICAL (it describes the Rails implementation); the
  pooler section's substance moves to the `doctor` subcommand's docs. **2026-10-14:** the banner
  points at `doctor` and at `src/services/doctor.rs`, whose own header carries the argument.

---

## 10. Risks and open questions

- **sqlx vs the Rails file (D2/D3).** The whole reversibility story rests on byte-identical
  timestamp text and 0/1 booleans. 0.3 is the spike; 7.1 is the proof. If sqlx-sqlite cannot be
  made to write Rails' format through a newtype, bind strings instead of times on SQLite.
- **Search ordering across dialects.** `ORDER BY path` sorts by SQLite's BINARY collation and by
  the Postgres database's own collation; the Ruby server has the same property, so parity is
  per-database, not per-implementation. Run the corpus against the database engine the target
  deployment uses.
- **The cable identifier (0.2) — resolved.** The Ruby host rejects the client's CONNECTION (no Origin
  header), not just the identifier, so the deployed desktop client has been polling all along; the
  Rust server accepts both and thereby changes observable latency, which §7.3 now says.
- **`expires_at` parsing.** Rails silently nulls an unparseable value (a link meant to expire
  never does). 0.1 records the current behaviour; changing it is a wire change to decide
  separately, after cutover, with a re-recorded scenario.
- **Enabling the reapers (§7.4)** deletes bytes the Ruby deployment never deleted. The dry-run
  step is not optional; the storage reaper's 24 h grace assumes a client never keeps a commit
  open longer, which the desktop client's own daemon honours but a hand-rolled client might not.
- **Postgres coverage** depends on a Linux runner this repo does not have (0.4). Without it, the
  Postgres claim is manual until Phase 6 says otherwise in its PR body — say so rather than let a
  `TEST_DATABASE_URL`-gated skip read as green (CLAUDE.md §5, "a guard that skips on the thing it
  asserts is vacuous").
- **Effort.** The Ruby engine is ~4,000 lines to port, with generous comments; expect ~6–8k lines of Rust
  including tests. Phase 0 is the cheapest place to find surprises and the only phase whose
  output (recorded scenarios) is useful even if the port stalls.
