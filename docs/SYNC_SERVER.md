# Sync server (Rails) — implementation notes

> **HISTORICAL — the Rails implementation, deleted from this repository in Phase 6 (2026-10-14).**
> This describes the Ruby engine and host that served the v1 API until production cut over to the
> Rust binary on 2026-10-07 (`docs/superpowers/plans/2026-10-07-rust-cutover.md`), and that left
> with Phase 6 of `docs/superpowers/plans/2026-09-30-rust-rewrite.md`. Every `app/`, `lib/`,
> `host/`, `db/` and `test/` path below, every `Sync::` class and every `bin/rails` command is gone
> from the tree; read them where `main` last had them, `git show 36bb82e:<path>`. Read this for
> **why** — the `next_seq!` lock-ordering argument, the statement-mode pooler hazard, the storage
> backends' reasoning — and **not** for what runs today: that is `crates/tinkerex-sync` (its
> README) and this repository's `CLAUDE.md`.
>
> **The pooler section's substance is the `doctor` subcommand now.** `tinkerex-sync doctor` runs
> the probe `Sync::PostgresPoolerCheck` ran — one transaction, two statements that must see the
> same backend pid, and a session advisory lock that must still be held at the second — and
> `serve` runs it at boot on Postgres: warning by default, refusing to boot with
> `SYNC_DB_POOLER_CHECK=refuse`, skipped with `SYNC_DB_POOLER_CHECK=skip` or
> `DB_SKIP_POOLER_CHECK=1` (`crates/tinkerex-sync/src/services/doctor.rs`). The section's finding
> that **nothing invokes the check** was true of the Rails host and is not true of the binary.

> **Moved here from `chaim354/tinkerex` on 2026-08-25.** It was written while this engine lived in
> that repo, so its opening line — "the Rails app *is* the sync engine's source of truth" — had
> become false there and is true again here. Paths below are relative to THIS repository unless
> they say otherwise. Spot-checked on arrival: `Sync::Commit`, `Sync::Mutation`, `Sync::Restore`,
> `Sync::Changes`, `Sync::Tree`, `Sync::Gc`, the chunk stores and `lib/sync/postgres_pooler_check.rb`
> all resolve. **One claim did not — see the pooler section.**

Implements `docs/sync-protocol.md`. The Rails app *is* the sync engine's source of
truth; client devices push to it and pull from it. Bytes never pass through Rails —
clients PUT/GET chunks directly to object storage via presigned URLs.

## What's built

- **Schema** (`db/migrate/.../create_sync_engine.rb`): `users(head_seq)`, `devices`,
  `nodes`, `versions`, `manifest_chunks`, `chunks(refcount)`, `changelog_entries`,
  `pending_commits`. Adapter-agnostic — runs on SQLite and PostgreSQL.
- **Models** (`app/models`): with the per-user changelog cursor (`User#next_seq!`).
- **Services** (`app/services`):
  - `Sync::Commit` — two-phase content commit (begin → missing/presign → finalize).
  - `Sync::Mutation` — the changelog invariant for metadata ops.
  - `Sync::Restore`, `Sync::Changes`, `Sync::Tree`, `Sync::Gc`.
  - `Storage::ChunkStore` (+ `S3ChunkStore` for R2/S3, `MemoryChunkStore` for tests).
- **API** (`app/controllers/v1`): see below.
- **ActionCable** (`LibraryChannel`): broadcasts `head_seq` on every commit.
- **Tests** (`test/`): full server suite green on SQLite (and on Postgres) — full HTTP flow,
  service-level dedup/refcount/restore/idempotency, auth/pairing, conflict detect/resolve,
  GC/retention + storage-orphan reaper, concurrent-`next_seq!` no-deadlock. Current count in
  `docs/STATUS.md`.

## API (v1)

| Method & path | Body / params | Returns |
|---|---|---|
| `POST /v1/auth/register` | `email`, `device_name` | `device_token`, `head_seq` (device bootstrap; new-account-only — see Auth note) |
| `POST /v1/devices` | `name` | another device token |
| `POST /v1/commit` | `commit_id, node_id, parent_node_id, name, base_version_id, size, manifest[]` | `missing[]`, `put_urls{}` |
| `POST /v1/commit/:commit_id/finalize` | — | `version_id`, `seq` |
| `GET /v1/changes` | `since`, `limit` | `changes[]`, `head_seq` |
| `GET /v1/tree` | `after_id`, `limit` | `nodes[]`, `head_seq`, `next_after_id` |
| `POST /v1/nodes` (mkdir) | `node_id, parent_node_id, name` | `seq` |
| `DELETE /v1/nodes/:node_id` | — | `seq` (tombstone; versions retained) |
| `POST /v1/nodes/:node_id/move` | `new_parent_node_id, new_name` | `seq` |
| `GET /v1/nodes/:node_id/versions` | — | `versions[]` |
| `POST /v1/nodes/:node_id/restore` | `version_id` | new `version_id`, `seq` |
| `POST /v1/chunks/download` | `hashes[]` | `urls{ hash => presigned GET }` |
| WebSocket `/cable` | `?token=` | `LibraryChannel` → `{head_seq}` on change |

Auth: `Authorization: Bearer <device_token>`. **Auth note:** `register` creates a **new account
only** (no `find_or_create_by` takeover); additional devices join an existing library via a
single-use, expiring **pairing code** (`DevicePairing`), not by re-registering. Real auth
(Rails 8 built-in: signup → email-confirm → login/reset, `Session`, OmniAuth seam) sits in front
of this device-token bootstrap; it is no longer a placeholder. See `CLAUDE.md` §8 + the
`[[auth-decision]]` project memory.

## Adapter-agnostic, without compromising performance

Everything uses portable, fast ActiveRecord — no PostgreSQL-only SQL in the hot path:
- `insert_all` for manifest chunks + new chunks (bulk).
- `update_all("refcount = refcount + 1")` for refcount bumps.
- `User#next_seq!` uses `lock!` — `SELECT … FOR UPDATE` on Postgres (serializes a
  user's concurrent commits), a harmless reload on SQLite (which serializes writes
  globally anyway). Correct and fast on both.
- Stable cross-device ids are string UUIDs; internal PKs are bigint. Indexed lookups.

Dev/test run on **SQLite** (which proves the portability). Switch to **PostgreSQL**
for managed with config only (no model or service code changes — schema + queries are
identical):

```ruby
# Gemfile — `pg` is already present; `aws-sdk-s3` is required lazily by the S3/R2 store.
```
```
DATABASE_URL=postgresql://USER:PASS@HOST:5432/maker_prod   # selects the postgres profile
```
The `postgres` profile in `config/database.yml` reads `DATABASE_URL`. **TLS** and the
**Solid stores** are handled automatically for a managed (Postgres) deploy — see below.

### Managed-Postgres hardening (G2)

**`next_seq!` concurrency + the lock-ordering invariant.** The per-user changelog `seq`
is the one true serialization point: every mutating transaction (`Sync::Commit#finalize`,
`Mutation#apply`, `Restore`, `Conflicts#keep/#split`) calls `User#next_seq!`, which takes
`SELECT … FOR UPDATE` on the user row. **It MUST be the first write in the transaction.**
The other rows a commit writes (node/version/changelog/chunk) all FK-reference `users`, and
a Postgres FK insert takes a `FOR KEY SHARE` lock on that users row. If a commit inserted
those *first* and locked *second*, two concurrent commits for one user would each hold KEY
SHARE and both want FOR UPDATE → a **lock-upgrade deadlock**. (This was a real bug, caught by
the load test below at 32×50 concurrent commits, and fixed by locking up front.) A
concurrent-commit **load test** proves the invariant — it hammers `next_seq!` and the full
commit path from many threads, each on its own connection, and asserts the allocated seqs are
exactly `1..N` (gapless, duplicate-free, no lost updates):

```sh
# SQLite (CI default — still exercises the invariant; SQLite serializes writes globally):
bin/rails test test/services/sync/concurrent_seq_test.rb
# Postgres (the real proof — a statement-mode pooler would surface as duplicates here):
DATABASE_URL=postgresql://… SEQ_LOAD_THREADS=32 SEQ_LOAD_PER_THREAD=50 \
  bin/rails test test/services/sync/concurrent_seq_test.rb
```
Verified clean to 48×80 (3840) concurrent commits on Postgres 16.

**Connection pooler — MUST be session or transaction mode, NEVER statement mode.** Because
`next_seq!`'s `FOR UPDATE` lock spans the read+write of `head_seq` within one transaction, all
of that transaction's statements must run on **one backend connection**. A pooler in
**statement** mode (PgBouncer `pool_mode = statement`) routes each *statement* to a possibly
different backend → it silently breaks the lock (and prepared statements), risking duplicate
seqs and changelog corruption. Use:
- **PgBouncer**: `pool_mode = transaction` (or `session`).
- **RDS Proxy / Supabase / Neon pooler**: transaction mode.

**THIS IS NOT ENFORCED AT BOOT ANYWHERE TODAY, AND THIS PARAGRAPH SAID IT WAS UNTIL 2026-08-25.**
`lib/sync/postgres_pooler_check.rb` (`Sync::PostgresPoolerCheck`) is here, is correct, and is
tested — but **nothing invokes it**. The initializer that used to run it lived in the maker app and
was deleted when this engine was extracted; the module came across without one, and
`host/config/initializers/` holds only `limits_concurrency_shim.rb`. `grep -rn PostgresPoolerCheck`
outside `test/` returns comments and no call. So the protection described below is **available, not
active** — the same shape as a guard that has never failed. Wiring it is a deliberate decision
rather than a tidy-up, because a boot probe that REFUSES to start would take a running deployment
down precisely when it is misconfigured, which is its job but is not a thing to switch on by
accident.

When wired, it probes the connection — opens a transaction, checks two
statements share a backend pid and a session advisory lock stays held — and **refuses to boot**
if it detects statement-mode pooling, with a fix hint. Best-effort; opt out with
`DB_SKIP_POOLER_CHECK=1` once you've verified the mode yourself. No-op on SQLite.

*Could we avoid `FOR UPDATE` to be more pooler-robust?* Two alternatives were weighed and
rejected for now: (a) a **Postgres `SEQUENCE`/`bigserial`** — gapless-free and pooler-mode-
agnostic, but sequences are *non-transactional* (a rolled-back commit burns a number → **gaps**),
they're PG-only (breaks the SQLite self-host path), and the changelog contract wants tight
`1..N` so a far-behind device's delta math stays simple; (b) a **transaction-level advisory
lock** (`pg_advisory_xact_lock(user_id)`) instead of the row lock — also PG-only and still needs
non-statement pooling to be transaction-scoped, so it buys nothing over the row lock. The row
lock is correct on *both* adapters, gapless, and—now that it's taken first—deadlock-free; the
only real requirement it imposes is non-statement pooling, which we now assert at boot. So we
**keep the row lock**.

**TLS / sslmode.** The `postgres` profile defaults `sslmode` to **`require`** for any non-local
host (a managed deploy is encrypted by default) and **`prefer`** for `localhost`/`127.0.0.1` (so
the Docker/dev box with no TLS still connects). Override with `DB_SSLMODE`; for full MITM
protection on a real managed deploy use `DB_SSLMODE=verify-full` plus `DB_SSLROOTCERT=/path/to/
provider-ca.pem` (Neon/RDS publish a CA bundle). A `sslmode` already in `DATABASE_URL` wins
(libpq precedence). Neon/Supabase URLs typically already carry `?sslmode=require`.

**Solid Queue / Cache / Cable.** Self-host keeps each on its **own SQLite file** (one box, local
disk — the right default). A **managed (Postgres) deploy moves them onto Postgres**: a managed
deploy is multi-instance and/or has ephemeral local disk, so a per-instance SQLite queue is
wrong (jobs enqueued on instance A are invisible to a worker on instance B, and a redeploy drops
the queue). When `DATABASE_URL` is Postgres, the `production` block puts each Solid role on its
**own Postgres database** (`…_cache` / `…_queue` / `…_cable`, derived from the primary DB name;
override any with `SOLID_CACHE_DATABASE_URL` / `SOLID_QUEUE_DATABASE_URL` /
`SOLID_CABLE_DATABASE_URL` — e.g. to park them on a cheaper instance). Separate databases isolate
their churn/locks from the primary. **Point the Solid roles at a session/transaction-mode pooler
too** (Solid Queue uses `FOR UPDATE SKIP LOCKED`). Verified on Postgres 16: all three schemas
load, a Solid Queue job persists, and a Solid Cache value round-trips cross-process. Migrate the
roles on deploy with `bin/rails db:prepare` (loads `db/{cache,queue,cable}_schema.rb`).

## Storage config (R2/S3)

```
STORAGE_BACKEND=s3
CHUNK_BUCKET=...           CHUNK_ENDPOINT=https://<acct>.r2.cloudflarestorage.com
CHUNK_REGION=auto          CHUNK_ACCESS_KEY_ID=...  CHUNK_SECRET_ACCESS_KEY=...
```
Tests/dev default to the in-memory store (`STORAGE_BACKEND=memory`).

Three backends:
- **`s3`** — R2/S3/SeaweedFS, the production + deployed data plane (bytes → object storage).
- **`memory`** — **control-plane only.** Mints fake `memory://` URLs and stores nothing, so the
  client's real PUT/GET data plane can't move bytes through it. Use it for HTTP-contract tests
  (the sync-engine integration suite), NOT for anything that actually transfers chunk bytes.
- **`local`** — a **real** filesystem-backed data plane with **no external object store** (no
  SeaweedFS/MinIO; permissive). Presigns real `http(s)://<host>/v1/chunks/blob/<user>/<hash>?exp&sig`
  URLs that the client PUTs/GETs; bytes land under `CHUNK_LOCAL_DIR` (default `tmp/chunk-store`).
  The URL is HMAC-signed with the Rails secret (keyed by user+hash+expiry), so it's untamperable +
  per-user-scoped — the same property as a presigned SigV4 key (§8). This is the self-hosted
  single-box option and what the **two-device real-mount tests** use to move bytes between two
  co-located mounts. Zero-config locally (presigned URLs point back at the request host); set
  `CHUNK_PUBLIC_URL` when the client reaches the server by a different host than it presents.
  ```
  STORAGE_BACKEND=local   CHUNK_LOCAL_DIR=/var/lib/maker/chunks   [CHUNK_PUBLIC_URL=http://host:3001]
  ```

## Versioning & GC (built for restore from day one)

Every commit writes an immutable `version` → content-addressed manifest; versions
chain via `parent_version_id` and share chunks. `chunks.refcount` = number of live
versions referencing a chunk. **Deleting a node only tombstones it — versions and
their chunks are retained, so restore always works.** Chunks are freed only when a
*version* is pruned by a retention policy (`Sync::Gc.prune_version!` decrements
refcounts; `Sync::Gc.sweep_orphans!` deletes refcount-0 chunk rows **and** their
storage objects after a grace period — `ChunkStore#delete` → S3/R2 `delete_object`,
best-effort/idempotent).

**Retention is wired** via `RetentionJob` (Solid Queue recurring, nightly 4am):

```
RETENTION_POLICY=keep_all   # default — self-host: never prunes (storage is the user's)
RETENTION_POLICY=tiered     # managed: <24h all, 1–30d daily, 30d–1y weekly, >1y monthly
```

Both modes ALWAYS keep a node's `current_version` and any **pinned** version
(`versions.pinned`). See `docs/versioning.md` for the keep-set math.

## Deferred (matches the spec)

Write-write conflict resolution (last-writer-wins now), sharing/multi-user, selective
sync, maker-app metadata, per-tenant chunk encryption, real OAuth (placeholder
device-token bootstrap today), and N+1 preloading in `Sync::Changes` (fine for small
deltas; the bulk path is `Sync::Tree`).

## Multi-tenancy note (per the 37signals reference)

v1 is **one user per library** with `user_id` scoping on a shared DB — simplest and
fully portable. If/when multi-user or db-per-tenant is wanted, the
[Active Record Tenanted](https://dev.37signals.com/rails-multi-tenancy/) pattern slots
over these same models (SQLite-per-tenant self-host, Postgres-per-tenant managed).
