# Sync Protocol — the v1 HTTP API

> **Moved here from `chaim354/tinkerex` on 2026-11-10.** It specifies the wire between this server
> and its clients: the maker app's `FileLayer::ChunkRemote` and `chaim354/tinkerex-client`. Paths
> under `app/`, `lib/`, `test/` and `config/`, and `CLAUDE.md §` numbers, are the maker app's.

**Status:** normative reference · **Last updated:** 2026-10-14

This document specifies the wire protocol between a sync client (a device) and a sync
server, well enough that an implementer who has never seen the Ruby source could build
a compatible server from it alone. It was written for the person who would
**rewrite the sync server in Rust**, and that rewrite is now the server: `chaim354/tinkerex-sync`
is the Rust binary under `crates/tinkerex-sync`, which production has run since 2026-10-07.
The Ruby implementation it replaced — a mountable Rails engine plus the standalone `host/`
Rails app that `LIBRARY_BACKEND=chunk_remote` clients talked to — was deleted in Phase 6
(2026-10-14), and the embedded form (`LIBRARY_BACKEND=chunk`) was retired on 2026-08-25.
**The `Sync::*` classes and Ruby paths cited below name where a rule was first read in that
implementation;** read them where its `main` last had them (`git show 36bb82e:<path>` in that
repo). The wire is what this document describes — and what that repo's recorded conformance
corpus pins, exchange by exchange, against the binary.

**How to use this document alongside the conformance corpus.** `chaim354/tinkerex-sync`
is growing a recorded conformance corpus at `conformance/` — `runner.rb` (the matcher:
exact, bidirectional, five escape hatches — `$capture`/`$ref`/`$type`/`$absent` plus bare
literals) and `schema.json` (the scenario file shape) are in place; **`conformance/scenarios/*.yml`
does not exist yet as of this writing.** Where a behavior below will eventually be pinned
by a recorded scenario, this document is prose derived from the controller/service code
plus whatever integration test currently exercises it — read the code and the cited test
if you need certainty beyond what's stated here. Once scenarios land, treat a `.yml` file
as the ground truth and this document as the map to it, not the other way around: prose
and fixtures that restate each other drift, and only one of them can be run against a
live server to catch that drift. **This document does not duplicate any scenario file's
content** — where one exists, it is named instead of re-described.

**Endpoint count: 26** (re-counted 2026-10-13 against `v1_routes.rb` in `chaim354/tinkerex-sync`;
that repo's `conformance/README.md` ends with the command that reports it), drawn from
`lib/tinkerex_sync/v1_routes.rb`'s `V1_ROUTES` lambda — the Ruby engine's single,
authoritative list, deleted with it in Phase 6. **The authoritative list is now the binary's
own:** `tinkerex-sync routes` prints every route it serves, and that repo checks the output
in as `conformance/routes.txt`, held to the binary byte for byte. Counted
by hand from the Ruby file, verb by verb, because it is exactly the kind of count that goes
wrong by hand — `resources :share_links, only: %i[create destroy]` alone expands to two
routes, not one:

| # | Method | Path |
|---|---|---|
| 1 | POST | `/v1/commit` |
| 2 | POST | `/v1/commit/:commit_id/finalize` |
| 3 | GET | `/v1/changes` |
| 4 | GET | `/v1/tree` |
| 5 | GET | `/v1/search` |
| 6 | POST | `/v1/nodes` |
| 7 | POST | `/v1/nodes/symlink` |
| 8 | DELETE | `/v1/nodes/:node_id` |
| 9 | POST | `/v1/nodes/:node_id/move` |
| 10 | GET | `/v1/nodes/:node_id/versions` |
| 11 | POST | `/v1/nodes/:node_id/restore` |
| 12 | POST | `/v1/nodes/:node_id/resolve_conflict` |
| 13 | GET | `/v1/conflicts` |
| 14 | GET | `/v1/trash` |
| 15 | POST | `/v1/trash/:node_id/restore` |
| 16 | POST | `/v1/nodes/:node_id/lock` |
| 17 | POST | `/v1/nodes/:node_id/unlock` |
| 18 | GET | `/v1/locks` |
| 19 | POST | `/v1/chunks/download` |
| 20 | POST | `/v1/share_links` |
| 21 | DELETE | `/v1/share_links/:id` |
| 22 | GET | `/v1/share/:token` |
| 23 | POST | `/v1/share/:token/download` |
| 24 | PUT | `/v1/chunks/blob/:user_id/:hash` |
| 25 | GET | `/v1/chunks/blob/:user_id/:hash` |
| 26 | POST | `/v1/admin/libraries` |

This excludes device enrollment (`POST /v1/devices`, `POST /v1/devices/login` on this
app; `POST /v1/devices`, `GET /v1/devices/whoami` on the sync server, served by the Ruby
`host/` app until Phase 6 and by the binary since) — **the drawer defined no device route
at all.** `Device` was a declared host obligation (`TinkerexSync::HOST_MODELS`), and its
token is the only credential this API accepts, so every real deployment supplies its own
enrollment endpoints outside the 25. See
[§3 Authentication](#3-authentication-device-tokens) for both real shapes. It also
excludes this app's own `V1::TestUsersController` (`/v1/test/users`, test-environment
only, this app's own bootstrapping helper, nothing to do with the sync engine).

---

## 1. What changed since the last version of this document

The previous version of this file was materially wrong or incomplete in five ways worth
naming, because a stale claim in a document loaded for architectural context is this
codebase's stated cardinal sin (CLAUDE.md §15's mutation-check rule; §14e's "a stale
open-list is worse than none"):

1. **"No write-write conflict handling yet... Last-writer-wins" was false.** Conflict
   detection and resolution are fully implemented and have been since before this
   document's previous revision: `Sync::Commit.finalize` detects a divergent base version,
   records both sides in a `conflicts` row, and emits a `conflict` changelog entry instead
   of silently overwriting; `GET /v1/conflicts` lists unresolved ones; `POST
   /v1/nodes/:id/resolve_conflict` resolves by keeping one side or splitting into siblings.
   See [§8.2](#82-post-v1commitcommit_idfinalize) for the detection algorithm and
   [§8.14](#814-get-v1conflicts)/[§8.15](#815-post-v1nodesnode_idresolve_conflict) for
   resolution.
2. **`POST /storage/read-token`, described as "a short-lived, prefix-scoped R2 read
   credential," does not exist and never did as a persistent credential.** Hydration is
   **per-chunk presigned GET URLs**, minted one batch at a time by `POST
   /v1/chunks/download` — there is no bulk, prefix-scoped read token anywhere in this
   API. See [§8.16](#816-post-v1chunksdownload).
3. **There is no `manifests` table.** The old data model described `manifests(manifest_id)`
   as a row-bearing entity distinct from `manifest_chunks`. In the real schema a manifest's
   existence is inferred entirely from whether any `manifest_chunks` row carries its id
   (`Sync::ManifestChunk.manifest_exists?`) — there is nothing else to it. See [§6](#6-data-model).
4. **The API surface table covered roughly a quarter of the real API** — trash/undelete,
   locks, conflicts, search, symlinks, conflict resolution, and share links were entirely
   absent. This revision covers all 25.
5. **Device registration was presented as part of "the" protocol.** It isn't part of the
   drawer at all, and the two real hosts implement it differently from each other (see
   [§3](#3-authentication-device-tokens)) — worth knowing before assuming a third
   implementation must match either one exactly.

What was *right* and is kept: the actor/topology shape, the "local metadata + async sync
+ on-demand hydration" framing, the three-channel description (HTTP / realtime nudge /
direct-to-storage), and the versioning-is-native, chunks-are-refcounted picture.

---

## 2. Topology

```
   Device A ─┐                  ┌────────────── sync server (control plane) ───────────┐
   Device B ─┼─ HTTPS /v1/* ───►│ device auth · tree · commit/finalize · changes        │
   Device C ─┘  WebSocket  ◄────│ presign minter · changelog · realtime nudge           │
        │                       │ DB: users(head_seq), devices, nodes, versions,        │
        │ direct chunk          │     manifest_chunks, chunks(refcount), changelog_     │
        │ PUT/GET (presigned)   │     entries, pending_commits, conflicts, file_locks,  │
        ▼                       │     share_links                                       │
   ┌────────────────────────────────────────────────────────┘
   │ object storage: chunks/<user_id>/<hash>  (content-addressed, immutable)
   │   S3/R2 in production; a colocated `local` HTTP tier (this API's own
   │   /v1/chunks/blob/*) for self-host without an external object store;
   │   `memory` for tests (control-plane only — mints URLs no HTTP client can use).
   └──────────────────────────────────────────────────────────────────────
```

Three real processes have answered this wire; one does today:

| Deployment | Where | Notes |
|---|---|---|
| Embedded engine — **retired 2026-08-25** | `chaim354/tinkerex` (this repo), `LIBRARY_BACKEND=chunk` | The engine mounted in-process via `Sync.draw_v1_routes`; `FileLayer::Chunk` was the in-process adapter. |
| Standalone host — **deleted in Phase 6, 2026-10-14** | `chaim354/tinkerex-sync`'s own `host/` | A small dedicated Rails app: the engine, the three host models, device enrollment, nothing else. What `LIBRARY_BACKEND=chunk_remote` clients (`FileLayer::ChunkRemote`, this repo) talked to over plain HTTP until the 2026-10-07 cutover. Verified end-to-end 2026-08-22: upload, finalize, changelog pull, local `stat`, byte read, `mkdir`, `move` (with `node_id` preserved), two separate processes, `Sync` undefined in the maker app's process throughout. |
| Rust rewrite — **the server** | `chaim354/tinkerex-sync`, `crates/tinkerex-sync` — **what production runs since 2026-10-07** (the `sync` Kamal accessory, image `…-rust`; cutover plan in that repo) | What this document was written for. Same wire, same paths and env as the Ruby host it replaced, free choice of internals. Graded not by this document alone but by that repo's recorded corpus — sixteen scenario files, `18 runs, 284 assertions, 0 failures, 0 skips`, against both the Ruby host and the binary until Phase 6 and against the binary alone since — and by this repo's `bin/sync-server`, which builds and boots it for `bin/ci test-chunk-remote`. |

A **device** holds a local SQLite mirror of the tree and a local chunk cache; metadata
reads never touch the network. Bytes move **client ⇄ object storage directly** —
control-plane requests never carry file content (the one deliberate, narrow exception is
the `local` chunk backend's own blob tier, [§10](#10-chunk-storage--presigning), which
exists specifically so a single self-hosted box needs no external object store).

---

## 3. Authentication (device tokens)

Every one of the 25 endpoints except the two anonymous share-redeem endpoints
(`GET /v1/share/:token`, `POST /v1/share/:token/download`) and the two HMAC-signed blob
endpoints (`PUT`/`GET /v1/chunks/blob/...`) requires:

```
Authorization: Bearer <device_token>
```

The server's device auth (`authenticate` in `crates/tinkerex-sync/src/auth.rs`; in the Ruby
engine, the `Sync::V1::Authentication` concern's `before_action :authenticate_device!` on
`Sync::V1::BaseController`, which every JSON-family controller inherited) reads the
header, strips a `Bearer ` prefix, and looks the token up by
`SHA256(token)` against `devices.token_digest` (the plaintext token is never stored). A
missing or unrecognized token is:

```
401 Unauthorized
{ "error": "unauthorized" }
```

There is no distinct "expired" or "revoked" status — a device's access is binary (its
row exists and its digest matches, or it doesn't); there is no token TTL or refresh flow
in this version of the API.

**Device enrollment is a declared host obligation, not part of the 25.** The Ruby engine drew
no device route at all (`TinkerexSync::HOST_MODELS` named `Device`; the engine's own
README: "obtaining a token is entirely yours"). The two real implementations differ from each
other, and a third is free to differ from both as long as it produces a bearer
token the server's device auth accepts:

- **This app** (`chaim354/tinkerex`) already has web users with passwords and sessions,
  so it exposes `POST /v1/devices/login {email, password, device_name}` → `201` with
  `{user_id, device_id, device_token, head_seq, library, sync}` (one generic `401
  {"error":"invalid_credentials"}` for any authentication failure — unknown email, wrong
  password, unconfirmed, locked — deliberately not distinguished, to avoid email
  enumeration), and `POST /v1/devices {name}` (authenticated by an existing device token)
  to enroll a sibling device for the same user → `201 {device_id, device_token, library,
  sync}`. Since the engine left this process, the top-level `device_token` opens **this
  app's own** v1 API (`/v1/maker/*`) and no sync route; a device syncs with the **sync
  grant** instead (since 2026-10-13):
  - `library: {backend, syncable}` — always; `backend` is `share`, `s3` or `chunk_remote`.
  - `sync: {url, device_token, user_id, device_id, head_seq}` on a syncable deployment
    (`chunk_remote`), `null` on share and s3. This app brokers it with the user's own
    bootstrap token on the sync server (`users.sync_device_token`, provisioned through the
    operator door `POST /v1/admin/libraries` if blank): it mints a sibling device there
    (`POST /v1/devices {name: device_name}`) and reads `head_seq` back **with the new
    token** (`GET /v1/devices/whoami`), which also proves the server accepts that token
    before it is handed out. `user_id`, `device_id` and `head_seq` are the sync server's;
    the top-level ones are this app's. `url` is `SYNC_PUBLIC_URL`, **the devices' door** to
    the sync server — deliberately not `CHUNK_REMOTE_URL`, the address this app itself
    dials; on a Kamal box the two differ. A device sends every route in this document to
    `sync.url` with `sync.device_token`.
  - A grant is minted per enrolment and never cached: a device that signs in twice is two
    sync devices, as it is two maker devices.
  - A sync server that cannot be reached, or refuses, answers `503
    {"error":"sync_unavailable"}` and **no maker device is minted** — the grant is brokered
    before the maker device, so a retry signs in from scratch.

  No sync-server route is added for this: the broker uses the sync server's own two,
  below.
- **The sync server** (the binary; the standalone `host/` app until Phase 6) has no
  users-with-passwords surface at all and deliberately does not invent one for a server
  whose only job is holding chunks. The *first* token for a user is minted by an operator:
  `tinkerex-sync device issue --email you@example.com` (the Ruby host's `bin/rails
  sync:device:issue`, same output) creates the user if absent and prints `user_id` / `device_id` /
  `device_token` **once** (only the digest is persisted — a lost token is reissued, not
  recovered). Every subsequent device is enrolled by an *already-authenticated* one via
  `POST /v1/devices {name}` → `201 {device_id, device_token}`. `GET /v1/devices/whoami`
  (authenticated) answers `{user_id, device_id, head_seq}` — a debugging aid, not something
  the reference client's sync loop calls (this app's broker, above, calls it once per
  enrolment).

---

## 4. Two wire families

Not all 25 endpoints share one response shape. There are two distinct families, and
conflating them is the single easiest mistake to make from a skim of the controllers:

**The JSON family (21 endpoints).** Everything under `Sync::V1::BaseController` (18
endpoints) plus `Sync::V1::ShareLinksController` (2, itself a `BaseController` subclass)
plus `Sync::V1::ShareController` (2, deliberately *not* a `BaseController` subclass —
[§8.17](#817-share-links)) always request and respond with `application/json`, and every
error is a JSON body with (at minimum) an `"error"` string key. [§5](#5-the-generic-error-envelope)
is its shared contract.

**The raw-bytes family (2 endpoints, `Sync::V1::Chunks::BlobController`).** `PUT`/`GET
/v1/chunks/blob/:user_id/:hash` take and return **raw bytes**
(`application/octet-stream`), are authorized by an **HMAC signature in the URL query
string**, not a bearer token, and error with **empty or plain-text bodies**, never JSON.
See [§8.18](#818-local-blob-tier-putget-v1chunksblobuser_idhash).

A client (or a server implementation) that assumes one error envelope for all 25
endpoints will mishandle the blob tier's failures.

---

## 5. The generic error envelope

`Sync::V1::BaseController` installs five `rescue_from` handlers, in this order, and their
handling is asymmetric in a way worth internalizing before reading individual endpoints:

| Raised | Status | Body | Preserves the raiser's message? |
|---|---|---|---|
| `ActiveRecord::RecordNotFound` | 404 | `{"error":"not_found"}` | **No — always the literal string `"not_found"`, regardless of what the exception said.** |
| `ActionController::ParameterMissing` | 400 | `{"error": "<e.message>"}` | Yes |
| `ActiveRecord::RecordInvalid` | 422 | `{"error": "<e.message>"}` | Yes |
| `ArgumentError` | 422 | `{"error": "<e.message>"}` | Yes |
| `ActiveRecord::RecordNotUnique` | 409 | `{"error": "<e.message>"}` | Yes |

**The 404 case is the trap.** `Sync::Conflicts.keep`/`.split` raise `RecordNotFound,
"no unresolved conflict for node"` when the node has no open conflict — but the client
never sees that sentence. Every `RecordNotFound`, from every source (`find_by!`, `.find`,
or an explicit `raise`), reaches the wire as exactly `{"error":"not_found"}` and nothing
more specific. Don't design a client that branches on 404 message text, and don't build a
Rust server that leaks a more specific message there — it would be observably different
from the reference implementation.

Three endpoints add their **own** `rescue_from`/inline `render` on top of this, each
narrower than the generic table and each documented at its own endpoint below:
`Sync::V1::CommitsController` (`InvalidManifest`→422, `KindConflict`→409,
`ChunksMissing`→422 with an extra `missing` key), `Sync::V1::NodesController` (a cycle
guard and a kind-change guard that `render` directly rather than raising), and
`Sync::V1::TrashController` (`ParentDeleted`→409 `{"error":"parent_deleted"}`).

**`Sync::V1::ShareController`** (the anonymous redeem side) does **not** inherit
`BaseController` and defines its own narrower error surface: `ParameterMissing` →
`head :bad_request` (**no body at all** — not even `{"error":...}`), and an invalid/dead
token → its own `not_found` helper, which happens to produce the byte-identical
`{"error":"not_found"}`, 404. See [§8.17](#817-share-links) for why this controller is
deliberately never capability-gated.

**A capability-gate 501** (`Sync::V1::CapabilityGate`) is its own shape, described fully
in [§7](#7-capability-gating). It fires from a `before_action`, so it always wins over
whatever the action body would have done.

---

## 6. Data model

Eight tables belong to the engine (`TinkerexSync`'s own migration surface); three more
(`users`, `devices`, `nodes`) are declared host obligations the engine's models `belongs_to
class_name: "::User"` against. Column lists below are the sync-relevant columns only — a
host's `nodes`/`users` tables may (and, in `chaim354/tinkerex`, do) carry additional
columns the engine never reads (e.g. `storage_path`, `content_hash` — share/s3-backend
concerns entirely outside this document's scope).

| Table | Key columns | Notes |
|---|---|---|
| `users` (host) | `id`, `head_seq` (bigint, default 0) | `head_seq` is the per-user monotonic changelog cursor. `User#next_seq!` = `lock!; head_seq += 1; save`. |
| `devices` (host) | `id`, `user_id`, `name`, `token_digest`, `last_seen_at` | `token_digest` = `SHA256(plaintext)`; the plaintext is never persisted. |
| `nodes` (host) | `node_id` (string, per-user-unique), `user_id`, `parent_node_id` (string, nullable), `name`, `kind` (`file`\|`dir`\|`symlink`), `current_version_id` (string, nullable), `deleted` (bool), `mode` (int, POSIX bits), `mtime` (bigint), `symlink_target` (binary), `updated_seq` (bigint) | `node_id` is a client-generated, stable UUID — the engine never mints one. **`parent_node_id` carries no foreign-key constraint and no existence check anywhere in the write path** — see [§13](#13-things-left-genuinely-unspecified). |
| `versions` | `version_id` (string, per-user-unique, server-minted `SecureRandom.uuid`), `node_id`, `manifest_id`, `size`, `parent_version_id`, `device_id`, `pinned` (bool) | Immutable once created. `parent_version_id` chains a version to the one it was committed against — history, not a live pointer. |
| `manifest_chunks` | `user_id`, `manifest_id`, `seq` (order within the manifest), `chunk_hash`, `offset`, `length` | **There is no separate `manifests` row.** A manifest's existence is `ManifestChunk.where(user_id:, manifest_id:).exists?` — any row at all. `manifest_id` = `SHA256(hex hashes joined)`, computed identically by client and server so both agree on dedup without a round trip. |
| `chunks` | `user_id`, `chunk_hash`, `size`, `refcount` (int, default 0) | One row per unique `(user, hash)`. Refcount is bumped on every manifest reference (new upload, restore, conflict split) and dropped only by retention pruning — see [§11](#11-refcounts-and-gc-not-part-of-the-wire). |
| `changelog_entries` | `user_id`, `seq` (per-user-unique), `node_id`, `op` (`put`\|`mkdir`\|`delete`\|`move`\|`conflict`\|`symlink`), `version_id` (nullable) | The pull feed. `seq` is assigned by `User#next_seq!` under a row lock — see [§8.2](#82-post-v1commitcommit_idfinalize) for why lock ordering matters. |
| `pending_commits` | `user_id`, `commit_id` (per-user-unique), `node_id`, `parent_node_id`, `name`, `manifest_id`, `manifest_json`, `base_version_id`, `size`, `mode`, `mtime`, `device_id` | The two-phase commit's staging row; destroyed on finalize. |
| `conflicts` | `user_id`, `node_id`, `incoming_version_id`, `current_version_id`, `resolved_at` (nullable) | Unique on `(user_id, node_id, incoming_version_id)` — N-way: several concurrent divergent edits on one node each get their own row. |
| `file_locks` | `user_id`, `node_id` (per-user-unique), `device_id`, `expires_at` | Best-effort, TTL-based. |
| `share_links` | `user_id`, `node_id`, `version_id`, `manifest_id`, `token_digest` (globally unique), `expires_at` (nullable), `revoked_at` (nullable) | A read-only capability over one **immutable version**, frozen at creation. |

`mtime` is stored as an opaque `bigint` and never interpreted by the server — no unit is
enforced. Both host adapters that produce it (`FileLayer::Chunk`, `FileLayer::ChunkRemote`,
in `chaim354/tinkerex`) use `(Time#to_f * 1e9).to_i` — **nanoseconds since the Unix
epoch** — but that is a convention observed in the two existing clients, not a constraint
the server checks or documents anywhere in code. `mode` is raw POSIX permission bits
(`0o755` for a directory, `0o644` for a file, `0o777` for a symlink are the observed
defaults when a client omits it).

**`op` is not one-op-per-endpoint, and `"put"` in particular is heavily overloaded.**
Every structural change gets its own distinctly-named op — `mkdir`
([§8.6](#86-post-v1nodes-mkdir)), `symlink` ([§8.7](#87-post-v1nodessymlink)), `move`
([§8.9](#89-post-v1nodesnode_idmove)), `delete` ([§8.8](#88-delete-v1nodesnode_id),
cascaded — one entry per affected node), `conflict` (the divergent-commit case inside
finalize, [§8.2](#82-post-v1commitcommit_idfinalize)). But **`"put"` means "this
node_id's `current_version_id` changed to a version that is now current"**, and five
distinct actions all produce it, indistinguishably, on the wire: a non-conflicting content
commit ([§8.2](#82-post-v1commitcommit_idfinalize)), a version restore
([§8.11](#811-post-v1nodesnode_idrestore)), a trash restore
([§8.12](#812-trash--undelete-and-the-to_root-divergence)), a conflict resolved by keeping
one side, and *each sibling* created by resolving a conflict via split
([§8.15](#815-post-v1nodesnode_idresolve_conflict)). A client that needs to tell these
apart cannot do it from `op` alone — the changelog entry itself carries no marker
distinguishing "this `put` was a fresh upload" from "this `put` was a restore." If that
distinction matters to a client, it has to be inferred some other way (e.g. comparing
`version.parent_version_id` against what it already knows), not read off `op`.

---

## 7. Capability gating

`Sync::V1::CapabilityGate` (`require_capability!`, a `before_action`) asks one of two
host-configurable questions before an action runs — **before**, never as a rescue, because
`NotImplementedError` is a `ScriptError` a bare `rescue` cannot catch, so a rescue-shaped
gate would silently not work at all (this reasoning is load-bearing enough that it is
repeated verbatim from `LibraryCapabilities`, the pattern this concern mirrors).

A **standalone engine with no host wiring answers every capability `true`, unconditionally
— by construction, not as a placeholder.** A bare sync server *is* the sync engine: it has
a changelog, chunks, devices and versions for as long as the process runs. The capability
question exists only because a **host** can be configured against a backend with none of
that (a share/s3 mounted-directory library, in `chaim354/tinkerex`'s case) — a fact about
the host's storage choice, never about the engine itself. A Rust rewrite that is *only*
ever the sync server (never embedded behind a host's own capability question) can
legitimately skip this gate entirely and still be wire-compatible — the observable
behavior is identical to always answering available.

When a capability **is** unavailable, every gated action answers:

```
501 Not Implemented
{ "error": "<capability>_unavailable: <message>[ <hint>]" }
```

joined by spaces, with `hint` omitted (not merely blank) when the gate declares none. The
two capabilities the sync surface asks about, and the **exact** message text
`chaim354/tinkerex` wires in (a Rust rewrite building its own host wiring may choose its
own wording — nothing in the engine hard-codes it — but should preserve the
`"<capability>_unavailable: "` **prefix**, since that substring, not the trailing prose,
is what `test/integration/v1/capability_gating_test.rb` and the reference client's own
[error mapping](#12-reference-client-error-mapping) key on):

| Capability | Example message (host-supplied) |
|---|---|
| `syncable` | `syncable_unavailable: this deployment has no sync engine. A share- or s3-backed library has no changelog, no chunks, and no devices syncing it (spec §3.3).` |
| `versioned` | `versioned_unavailable: this deployment keeps no file history. A share- or s3-backed library is current-state only (spec §2 decision 4), so there is nothing to list or restore.` |

**Which of the 25 endpoints gate on which capability** (from
`test/integration/v1/capability_gating_test.rb`, which drives every one of these as a real
HTTP request against a deliberately capability-less backend and asserts both the 501 and
its exact message prefix):

| Capability | Endpoints |
|---|---|
| `syncable` | `GET /v1/changes` · `GET /v1/tree` · `GET /v1/conflicts` · `GET /v1/locks` · `GET /v1/trash` · `POST /v1/trash/:id/restore` · `POST /v1/commit` · `POST /v1/commit/:id/finalize` · `POST /v1/chunks/download` · `POST /v1/nodes` · `POST /v1/nodes/symlink` · `DELETE /v1/nodes/:id` · `POST /v1/nodes/:id/move` · `POST /v1/nodes/:id/lock` · `POST /v1/nodes/:id/unlock` · `POST /v1/nodes/:id/resolve_conflict` |
| `versioned` | `GET /v1/nodes/:id/versions` · `POST /v1/nodes/:id/restore` · `POST /v1/share_links` |
| **ungated, deliberately** | `GET /v1/search` · `GET /v1/share/:token` · `POST /v1/share/:token/download` · `DELETE /v1/share_links/:id` · both `/v1/chunks/blob/*` endpoints |

Two of the ungated cases are worth stating plainly rather than leaving as an omission:

- **`GET /v1/search`** queries the `nodes` table directly via a recursive CTE
  ([§8.5](#85-get-v1search)) — that table is populated on every backend a host might run
  (via the changelog on a syncable one, via a directory/bucket scan on others), so search
  works regardless of whether *this* engine's sync machinery is in the picture at all.
  Proven directly: `capability_gating_test.rb`'s "the maker layer is NOT gated in share
  mode" test calls `GET /v1/search?q=a` against a capability-less backend and asserts 200.
- **The anonymous share-redeem side is ungated on purpose, not by oversight.** A 501 there
  would tell an anonymous stranger holding any string which backend a deployment runs; 404
  is already both honest and terminal, because the *owner* side (`POST /v1/share_links`) is
  what's gated on `versioned` — no link can exist to redeem on a deployment that can't mint
  one, so `redeem!` finds nothing and says so truthfully either way.

---

## 8. Endpoint reference

Per-endpoint entries below state, where they differ from the shared rules already given:
capability gate, request shape, success response, and every error status *specific* to
that endpoint (the shared 401/[capability-gate 501] rules are not repeated per entry).
**"Pinned by"** names the current best evidence for the behavior described — an HTTP
integration test, a service-level test, or (honestly) neither beyond the source read
directly. None of these are `conformance/scenarios/*.yml` files, because none exist yet.

### 8.1. `POST /v1/commit`

**Capability:** `syncable`. Phase 1 of the two-phase upload: stage the commit, learn which
chunks (if any) still need uploading, get presigned PUT URLs for exactly those.

Request body (all keys via `params.permit`, **not** `params.require` — see the note
below):

```json
{
  "commit_id": "<client-generated UUID, idempotency key>",
  "node_id": "<stable per-file UUID>",
  "parent_node_id": "<parent's node_id, or omit/null for root>",
  "name": "part.stl",
  "base_version_id": "<the version_id this edit is based on, or null for a new file>",
  "size": 1048576,
  "mode": 420,
  "mtime": 1755999999000000000,
  "manifest": [ { "hash": "<64-hex sha256>", "offset": 0, "length": 65536 }, "..." ]
}
```

Success — `200`:

```json
{ "commit_id": "...", "missing": ["<hash>", "..."], "put_urls": { "<hash>": "https://..." } }
```

`missing` is the subset of `manifest`'s hashes this user doesn't already have a `chunks`
row for (content-addressed dedup: identical bytes anywhere in the user's library are never
re-uploaded). `put_urls` has one presigned-PUT entry per missing hash — upload only those,
then call finalize.

**Validation and its errors are asymmetric with `POST /v1/nodes` — read carefully.**
Because this action uses `.permit`, not `.require`, a missing `node_id`/`name` does
**not** produce the 400 `ParameterMissing` you'd get from the mkdir endpoint. Instead the
staging row's own `ActiveRecord` validations (`commit_id`/`node_id`/`name`/`manifest_id`
all `presence: true`) fire on `save!`, surfacing as:

| Condition | Status | Body |
|---|---|---|
| `commit_id`/`node_id`/`name` blank | 422 | `{"error": "Validation failed: <field> can't be blank[, ...]"}` (Rails' standard `RecordInvalid` message) |
| A manifest entry's `hash` isn't 64 lowercase hex chars | 422 | `{"error": "invalid chunk hash(es): <first 3, inspected>"}` |
| More than 100,000 manifest entries (`Sync::Commit::MAX_MANIFEST_CHUNKS`) | 422 | `{"error": "manifest too large (<n> > 100000)"}` |

The hash-shape check exists specifically to keep a crafted hash like `"../7/deadbeef"` from
ever becoming a storage key (`chunks/<user>/<hash>`) or a DB row — reject at the door,
never normalize. `size`, `mode`, `mtime` all silently coerce a missing/garbage value via
`.to_i` (so an absent `size` becomes `0`, not an error).

Re-`begin`ning the same `commit_id` (retry after a dropped response) is safe **only
because it's an upsert, not a guarded no-op**: `find_or_initialize_by(commit_id:)` finds
the existing staging row if one exists, but every field is then unconditionally
reassigned from the new request and saved. Calling it twice with *identical* parameters
is indistinguishable from calling it once — the retry case this is meant to support. But
nothing rejects or even notices a second call for the same `commit_id` carrying a
*different* manifest, `node_id`, or `name`: the second call's data silently replaces the
first's. A client that generates a fresh `commit_id` per logical commit (as every existing
caller does) never hits this; a client that reused one across genuinely different commits
would get silent data replacement, not an error.

**Pinned by:** `test/integration/v1/node_guards_test.rb` ("commit with a traversal chunk
hash is rejected (422)"); the `commit_file` helper shared across `trash_flow_test.rb`,
`node_guards_test.rb`, `tenant_isolation_test.rb` exercises the happy path repeatedly;
`capability_gating_test.rb` for the 501.

### 8.2. `POST /v1/commit/:commit_id/finalize`

**Capability:** `syncable`. Phase 2: atomically create the immutable version, update the
node, and append the changelog entry.

Request body: `{}` (nothing required — the commit_id in the path is the only input; the
staged row from phase 1 supplies everything else).

Success — `200`:

```json
{ "version_id": "<server-minted UUID>", "seq": 42 }
```

**Verification is opt-in, and its default is a production choice, not a test artifact.**
When `Rails.configuration.x.verify_finalize` is true (`SYNC_VERIFY_FINALIZE`, default `1`
— on unless explicitly disabled), finalize HEADs storage for every manifest hash not
already known in the DB before creating the version, so a client that lied about
uploading (or crashed mid-upload) can't mint a version pointing at bytes that were never
written:

```
422 Unprocessable Entity
{ "error": "chunks_missing", "missing": ["<hash>", "..."] }
```

This is its **own** shape, not the generic error envelope — note the extra `missing` key
and the fixed `"chunks_missing"` error string, both load-bearing for a client that's meant
to re-PUT exactly those hashes and retry finalize.

**A kind conflict** — finalizing onto a `node_id` that already exists as a `dir` or
`symlink` — is refused rather than silently flipping the node's kind (which would orphan
its children/target):

```
409 Conflict
{ "error": "node <id> already exists as a <dir|symlink>, cannot become a file" }
```

**Conflict detection** happens inside this action, silently, with no distinct error status
— the full algorithm follows. The response shape above (`{version_id, seq}`) is identical
whether the commit landed as the new current version or was recorded as a conflict; the
only way to learn which happened is to notice the node's `current_version_id` didn't move
(via a subsequent `GET /v1/changes` or `GET /v1/tree`) or to poll `GET /v1/conflicts`.

#### How finalize decides a commit is a conflict

A finalize is a **conflict** iff *all four* hold:

1. The node already existed (`node.persisted?`) before this commit.
2. It already had a `current_version_id` (i.e. this isn't the first version).
3. The commit's `base_version_id` (from phase 1) is present.
4. That `base_version_id` is **not** the node's current version — i.e. someone else's
   commit landed in between the client reading its base and this finalize.

**Exception — the same-device fast-forward rule.** If the version currently sitting as
`current_version_id` was itself committed by the **same device** as the one finalizing
now, condition 4's mismatch is *not* treated as a real conflict, even though it
technically satisfies the check above. This is deliberate: a sync daemon that pushes an
edit, then pulls its own change back down (advancing local state), then retries or
follows up with a second write still carrying the pre-echo `base_version_id`, is racing
its own echo — not diverging from another device. A genuine conflict requires a
*different* device to have moved `current_version_id`. Concretely: fast-forward (treat as
an ordinary `put`, no conflict) whenever `prior_version.device_id == pending.device_id`.

**When it *is* a conflict:** both versions are kept in full (chunks are content-addressed
and refcounted, so the only new cost is whatever bytes the incoming commit actually
introduced) — the node's `current_version_id` does **not** move to the incoming version,
the changelog entry's `op` is `"conflict"` instead of `"put"`, and a `conflicts` row is
created keyed by `(user_id, node_id, incoming_version_id)` — **not** by `node_id` alone.
That keying is what makes this N-way: three or more devices diverging from the same base
before any of them syncs each get their **own** conflict row (recording that device's
`incoming_version_id` against the `current_version_id` that was live when it landed),
rather than a later divergent push overwriting an earlier one's row and silently losing
track of it. See [§8.14](#814-get-v1conflicts)/[§8.15](#815-post-v1nodesnode_idresolve_conflict)
for how a conflict is surfaced and resolved.

Finalize is retry-safe after an upload-side failure: re-calling finalize for a `commit_id`
whose chunks are now genuinely present succeeds normally. A `commit_id` finalized once and
never retried again leaves no dangling row (the `pending_commits` row is destroyed inside
the same transaction that creates the version).

**Lock ordering inside the transaction is a correctness requirement, not an
implementation detail free to vary.** Finalize allocates its `seq` (`user.next_seq!`,
which takes a row lock on `users` — `SELECT ... FOR UPDATE` under Postgres) as the
**first** statement inside its transaction, strictly before any write to `nodes`,
`versions`, `chunks`, or `changelog_entries`. This is not incidental ordering: every one
of those writes carries a foreign key to `users`, and under Postgres an FK-referencing
`INSERT`/`UPDATE` takes a `FOR KEY SHARE` lock on the row it references. If seq allocation
happened *after* those writes instead, two commits for the same user running concurrently
could each already hold `FOR KEY SHARE` (from their own FK writes) and then both attempt
to upgrade to `FOR UPDATE` for the seq lock — a lock-upgrade deadlock, observed live under
load in the existing implementation before this ordering was enforced everywhere. Locking
first means every commit acquires the strong lock before touching anything FK-bound, so
concurrent commits against one user serialize cleanly instead of deadlocking. **This rule
applies to every mutating endpoint, not just finalize** — mkdir/symlink/move
([§8.6](#86-post-v1nodes-mkdir)/[§8.7](#87-post-v1nodessymlink)/[§8.9](#89-post-v1nodesnode_idmove)),
the subtree delete cascade ([§8.8](#88-delete-v1nodesnode_id)), version restore
([§8.11](#811-post-v1nodesnode_idrestore)), trash restore
([§8.12](#812-trash--undelete-and-the-to_root-divergence)), and conflict resolution
([§8.15](#815-post-v1nodesnode_idresolve_conflict)) all take the user lock and mint their
`seq`(s) before any other write in the same transaction. A from-scratch implementation
against a database with the same FK-lock-upgrade behavior (Postgres; SQLite's
single-writer model doesn't have this exact failure mode, but the ordering is free to keep
regardless) should preserve this ordering rather than rediscovering it under concurrent
load.

**Pinned by:** `test/integration/v1/node_guards_test.rb` ("finalizing a commit whose
chunks were never uploaded is rejected", "committing a file onto an existing dir node is
rejected (409)"); `commit_finalize_transaction_boundary_test.rb` (proves the host-hook
publish, [§9](#9-realtime-notifications-actioncable), fires strictly after the commit
transaction commits — a detail that matters for a host, not for the wire itself);
`capability_gating_test.rb` for the 501.

### 8.3. `GET /v1/changes`

**Capability:** `syncable`. The incremental pull: every changelog entry with `seq >
since`, each carrying enough of the node (and, for content commits, the version +
manifest) for a client to update its local mirror without a second round trip.

Query params: `since` (integer, default `0` — a garbage/non-numeric value silently
`.to_i`s to `0`, never a 400), `limit` (integer, default `500`, clamped to `[1, 2000]` —
same silent-clamp behavior for garbage input).

Success — `200`:

```json
{
  "changes": [
    {
      "seq": 43, "op": "put", "node_id": "...",
      "node": { "node_id": "...", "parent_node_id": "...", "name": "...", "kind": "file",
                "deleted": false, "mode": 420, "mtime": 1755999999000000000 },
      "version": { "version_id": "...", "manifest_id": "...", "size": 1048576 },
      "manifest": [ { "hash": "...", "offset": 0, "length": 65536 } ]
    }
  ],
  "head_seq": 43,
  "oldest_seq": 1
}
```

`node` is present for every op except one whose node has since vanished entirely (not
expected in normal operation — nodes are tombstoned, never hard-deleted). `version` and
`manifest` are present only when **all** of: `op == "put"`, the entry names a
`version_id`, **and that version row still resolves** — every other op (`mkdir`, `delete`,
`move`, `conflict`, `symlink`) omits both keys rather than sending them `null`, and so
does a `"put"` entry whose named version has since been pruned by a retention policy
([§11](#11-refcounts-and-gc-not-part-of-the-wire)) while its older changelog entry was
not (changelog pruning and version pruning are independent sweeps with independent
criteria — an old `"put"` entry surviving past its version's own pruning is possible, not
merely theoretical). A `symlink`-kind node additionally carries `node.symlink_target`,
base64-encoded (the link target is arbitrary bytes, not guaranteed valid UTF-8, so it
can't ride as a bare JSON string).

**`oldest_seq` is the pruned-gap detector, and its empty-table case is the part easy to
get backwards.** It reports the oldest changelog entry this server still retains. If a
client's cursor is *below* `oldest_seq`, the entries it needs have been pruned by a
retention policy ([§11](#11-refcounts-and-gc-not-part-of-the-wire)) and it must fall back
to a full `GET /v1/tree` resync. When the changelog table is entirely empty (either
nothing has ever happened, or a full prune removed everything up to `head_seq`),
`oldest_seq` reports **`head_seq + 1`**, deliberately **not `0`** — reporting `0` there
would read as "nothing has ever been pruned," letting a genuinely-behind cursor
fast-forward past a real gap undetected. `head_seq + 1` sits strictly above any behind
cursor, so the gap is always caught.

**There is no explicit "more pages" flag.** A client paging through history keeps calling
with `since` set to the last returned entry's `seq` until it receives fewer than `limit`
entries (or none) — an implicit convention, not an enforced contract; preserve it rather
than adding an explicit flag, which would be a wire change no existing client expects.

**Pinned by:** `test/integration/v1/trash_flow_test.rb` ("restore appends a changelog
entry so other devices converge"); `node_guards_test.rb` (directory-delete cascade
producing one `delete` entry per affected node); `tenant_isolation_test.rb`
(cross-tenant isolation); `capability_gating_test.rb` for the 501 and for asserting the
body actually names the missing capability.

### 8.4. `GET /v1/tree`

**Capability:** `syncable`. The full-tree snapshot a device pairs with on first sync (or
after a pruned-gap resync).

Query params: `after_id` (integer, default `0` — an internal auto-increment `id`, **not**
`node_id`; opaque cursor, not meaningful to compare across users or to persist across a
schema migration), `limit` (default `1000`, clamped `[1, 5000]`).

Success — `200`:

```json
{
  "nodes": [
    { "node_id": "...", "parent_node_id": "...", "name": "...", "kind": "file",
      "mode": 420, "mtime": 1755999999000000000,
      "version_id": "...", "size": 1048576,
      "manifest": [ { "hash": "...", "offset": 0, "length": 65536 } ] }
  ],
  "head_seq": 43,
  "next_after_id": 91
}
```

Only **present** (non-tombstoned) nodes are included — `user.nodes.present`, i.e.
`deleted: false`. A `file`-kind node with a resolvable current version carries
`version_id`/`size`/`manifest`; a `symlink`-kind node instead carries base64
`symlink_target` (same encoding as the changes feed); a `dir`-kind node carries neither.
**`next_after_id` is `nil` on the last page** (`nodes.last&.id`, and `nodes` is empty on
an exhausted final page) — the same implicit-pagination convention as `/v1/changes`: keep
paging while the returned array is non-empty.

**Pinned by:** `node_guards_test.rb` (directory-delete cascade — asserts none of a
deleted subtree survives in a tree snapshot); `trash_flow_test.rb`; `tenant_isolation_test.rb`;
`capability_gating_test.rb`.

### 8.5. `GET /v1/search`

**Not capability-gated** — see [§7](#7-capability-gating). Substring search by basename
or full path, scoped to the caller's own tree, via one recursive CTE (no N+1, portable
across SQLite and Postgres: `WITH RECURSIVE`, `||` concatenation, `LIKE ... ESCAPE` are
all standard SQL both adapters support).

Query params: `q` (required in spirit, not in code — a **blank** `q` returns `{"results":
[]}` with `200`, never a 400, specifically to avoid dumping the whole tree on an empty
query), `limit` (default/max `200`, `Sync::Search::MAX_LIMIT`, clamped), `offset` (default
`0`, floored at `0`), `include_deleted` (boolean-ish, default `false` — when true,
tombstoned nodes are included, which is what powers a "search the trash" UI).

Success — `200`:

```json
{ "results": [ { "node_id": "...", "name": "...", "kind": "file", "path": "/a/b/c.stl", "size": 1048576 } ] }
```

`path` is reconstructed leading-slash-rooted (`/name/name/...`) by the recursive walk.
`size` is `null` for a directory or for a file with no resolvable current version. Matching
is case-insensitive substring on the lowercased path (so searching a parent folder's name
surfaces its descendants too). The recursive walk is depth-capped at 4096
(`Sync::Search::MAX_DEPTH`) purely as a defense against a cyclic `parent_node_id` chain —
not expected to bind on any real tree.

**Pinned by:** `test/integration/v1/tenant_isolation_test.rb` ("search never returns
another user's nodes (same name)"); `node_guards_test.rb` (search still returns promptly
after a rejected cyclic move, proving no runaway recursion); `test/services/sync/search_test.rb`
at the service layer; `capability_gating_test.rb`'s "the maker layer is NOT gated in share
mode" test drives this exact endpoint to prove it is ungated.

### 8.6. `POST /v1/nodes` (mkdir)

**Capability:** `syncable`. Creates a directory node, or re-parents/renames an existing
one in place (`find_or_initialize_by(node_id:)` — the same `node_id` twice is an update,
not a collision).

Request body: `{ "node_id": "...", "name": "...", "parent_node_id": "<or omit for root>",
"mode": 493, "mtime": 1755999999000000000 }`. **`node_id` and `name` use
`params.require`** — unlike commit — so a missing one is:

```
400 Bad Request
{ "error": "param is missing or the value is empty or invalid: node_id" }
```

(the literal Rails `ParameterMissing` message; wording may vary slightly across Rails
versions — the status and the presence of *a* descriptive message are the contract, not
this exact string).

Success — `201 Created`: `{ "node_id": "...", "seq": 44 }`. The changelog entry this
appends carries **`op: "mkdir"`** — see the note on `op` values at the end of
[§6](#6-data-model) for how this fits the full vocabulary.

Two guards, each rendering directly rather than raising (so they don't route through
[§5](#5-the-generic-error-envelope)'s table, though the shapes happen to match its `422`/`409`
rows):

- **Cycle guard** — re-parenting `node_id` under a `parent_node_id` that IS `node_id`, or
  is one of its own descendants, would let the tree's ancestor-walk spin forever (fatal on
  SQLite: no statement timeout). Walked up from the proposed new parent, bounded by a
  `seen` set even against an already-corrupt tree:
  `422 {"error": "move would create a cycle"}`.
- **Kind-change guard** — mkdir onto an existing **file** or **symlink** `node_id` would
  silently orphan its version history / link target:
  `409 {"error": "node <id> already exists as a <kind>, cannot become a dir"}`.

**Pinned by:** `node_guards_test.rb` (both cycle-guard tests use this endpoint as their
directory-creation helper; "mkdir on an existing file node is rejected (409)");
`trash_flow_test.rb` (the orphan-restore scenario builds its directory via this endpoint);
`capability_gating_test.rb`.

### 8.7. `POST /v1/nodes/symlink`

**Capability:** `syncable`. Creates or updates a symlink node — metadata-only, no
version/manifest, a single mutation the same shape as mkdir.

Request body: `{ "node_id": "...", "name": "...", "parent_node_id": "<or omit>",
"symlink_target": "<base64>", "mode": 511, "mtime": ... }`. `node_id`/`name` are required
the same way as mkdir (400 `ParameterMissing` if absent). `symlink_target` is **optional**
— if blank/absent, the node is created with a `nil` target rather than rejected; nothing
in the code treats an empty-target symlink as invalid.

Success — `201 Created`: `{ "node_id": "...", "seq": ... }`. Changelog `op: "symlink"`.

Same kind-change guard as mkdir (`409` if `node_id` already exists as a `file` or `dir`).
**No cycle guard** — a symlink can't have children, so re-parenting one carries no cycle
risk, and none is checked.

**Pinned by:** no dedicated HTTP integration test found for this action specifically.
Symlink *serialization* (the read side, in `GET /v1/changes` and `GET /v1/tree`) is
covered by `test/services/sync/changes_test.rb` and `tree_test.rb`. The write side above
is derived directly from `Sync::V1::NodesController#symlink`'s source.

### 8.8. `DELETE /v1/nodes/:node_id`

**Capability:** `syncable`. Tombstones the node **and its entire present subtree** in one
call — a directory delete cascades, so a `GET /v1/tree` snapshot and a changelog-following
device never disagree about whether a deleted folder's children are still there.

No request body. Success — `200`: `{ "seq": <the LAST seq minted, one per affected node> }`.
Every affected node gets its **own** `seq` and its own `delete` changelog entry (the
standard one-mutation-per-node changelog shape); only the final one rides back in the
response, since a client pulling `GET /v1/changes` afterward sees them all anyway.

Deleting is a **tombstone**, not a hard delete — `deleted: true`, versions and chunks
untouched (§6, §11). `POST /v1/trash/:id/restore` is the un-delete for exactly this state.

Unknown `node_id` → `404 {"error":"not_found"}`.

**Pinned by:** `node_guards_test.rb` ("deleting a folder tombstones the whole subtree in
tree AND changelog" — the most thorough test of the cascade, asserting both a `GET
/v1/tree` snapshot and a `GET /v1/changes` delta agree); `trash_flow_test.rb`;
`capability_gating_test.rb`.

### 8.9. `POST /v1/nodes/:node_id/move`

**Capability:** `syncable`. Re-parent and/or rename a node in place.

Request body: `{ "new_parent_node_id": "<or null>", "new_name": "<or omit>" }`. **Omission
and explicit `null` mean different things for `new_parent_node_id`** — the action checks
`params.key?(:new_parent_node_id)`, not merely truthiness: omitting the key entirely
leaves the current parent untouched; sending it as JSON `null` explicitly moves the node
to the root. `new_name` uses `.present?` instead, so an omitted, `null`, or blank name all
equally mean "don't rename."

Success — `200`: `{ "seq": ... }`. Changelog `op: "move"`. Same cycle guard as mkdir
(`422`, same message) when the proposed new parent is the node itself or one of its own
descendants. Unknown `node_id` → `404`.

**No existence check on `new_parent_node_id`.** Moving a node under a `parent_node_id`
that names no real node succeeds — see [§13](#13-things-left-genuinely-unspecified).

**Pinned by:** `node_guards_test.rb` (both cycle tests, plus "a legitimate move still
works"); `trash_flow_test.rb` (moving a file under a directory before deleting both, to
set up the orphan-restore scenario); `tenant_isolation_test.rb` (cross-tenant 404);
`capability_gating_test.rb`.

### 8.10. `GET /v1/nodes/:node_id/versions`

**Capability:** `versioned`. Up to 200 most-recent versions of one node, newest first.

Success — `200`:

```json
{ "versions": [ { "version_id": "...", "manifest_id": "...", "size": 1048576,
                   "parent_version_id": "...", "created_at": "2026-08-24T12:00:00.000Z" } ] }
```

(`created_at` is Rails' default ISO-8601 JSON time encoding.) Unknown `node_id` → `404`.
**Before this capability gate existed, an unversioned deployment answered `{"versions":
[]}`** — indistinguishable from "this file genuinely has no history" — which is exactly
the lie the gate exists to stop; a test asserts the 501 body does **not** match
`/"versions":\s*\[\]/`.

**Pinned by:** `capability_gating_test.rb` for the 501 case specifically (including the
"not an empty list" assertion above); `tenant_isolation_test.rb` for cross-tenant 404. The
200 happy-path field shape above is derived directly from
`Sync::V1::NodesController#versions`'s source — no HTTP-level test independently asserts
its exact fields today.

### 8.11. `POST /v1/nodes/:node_id/restore`

**Capability:** `versioned`. Restore a node to a **specific historical version** — distinct
from trash/undelete ([§8.12](#812-trash--undelete-and-the-to_root-divergence)), which
brings back a *deleted* node as it was at delete time. This creates a brand-new version
whose manifest is the **old** version's manifest (chunks already exist — refcounts bump,
nothing re-uploads), then propagates like any other write.

Request body: `{ "version_id": "<required>" }` — `params.require`, so a missing one is
`400`. `Sync::Restore.call` resolves `user.versions.find_by!(version_id:, node_id:)` — a
`version_id` that exists but belongs to a *different* node (or a different user) is
`404`, same as one that doesn't exist at all.

Success — `200`: `{ "version_id": "<the NEW version's id>", "seq": ... }`. Restoring also
clears any tombstone on the node (`node.deleted = false`) as a side effect — restoring a
deleted file's old content revives it. Changelog **`op: "put"`** — the same op a fresh
content commit uses; see the note at the end of [§6](#6-data-model) for why `"put"` covers
several distinct actions rather than each getting its own name.

**Pinned by:** `capability_gating_test.rb` (501); `tenant_isolation_test.rb` (cross-tenant
404). No HTTP-level happy-path test found; `test/services/sync/restore_test.rb` covers
`Sync::Restore.call` directly at the service layer.

### 8.12. Trash / undelete, and the `to_root` divergence

#### `GET /v1/trash`

**Capability:** `syncable`. Every tombstoned node for the user, unbounded, newest-deleted
first.

Success — `200`:

```json
{ "items": [ { "node_id": "...", "name": "...", "kind": "file", "parent_node_id": "...",
                "deleted_at": "2026-08-24T12:00:00.000Z", "size": 1048576, "version_id": "..." } ] }
```

`deleted_at` is the tombstone's `updated_at`. `size`/`version_id` come from the node's
`current_version_id` at time of deletion — both are `null` for a tombstoned directory
(which never had a version) or if that version's row is somehow gone. This is genuinely
**every** tombstone ever produced — there is no pagination and no time bound.

**Pinned by:** `test/integration/v1/trash_flow_test.rb`, extensively — happy path, a
query-cost regression guard (constant query count regardless of tombstone count, not a
literal — CLAUDE.md §14e's own rule about asserting constancy rather than a number),
cross-tenant isolation of the batched version-size lookup, and the nil-size edge cases
above.

#### `POST /v1/trash/:node_id/restore`

**Capability:** `syncable`. Un-tombstones a node, re-pointing it at the version it already
carries (`current_version_id`) — no new chunks, no re-upload, because deleting never
touched the version or its chunks in the first place.

Request body: `{ "to_root": <bool, default false> }`.

Success — `200`: `{ "node_id": "...", "parent_node_id": "...", "seq": ... }` (or `seq:
null` if the node wasn't actually tombstoned — an idempotent no-op, not an error). When a
mutation does happen, its changelog **`op` is `"put"`** — same overloaded op as a fresh
commit or a version restore; see the note at the end of [§6](#6-data-model).
Unknown `node_id` → `404`.

**If the node's parent is *itself* tombstoned (or gone)**, restoring the child into a
missing parent is refused unless the caller explicitly opts in:

```
409 Conflict
{ "error": "parent_deleted" }
```

Passing `to_root: true` instead restores the node **to the root** (`parent_node_id` set
to `null`) rather than raising. This is `Sync::Trash.restore`'s entire contract:
`to_root` defaults to `false`, and the server's behavior is exactly this — a strict
default that asks the caller to decide, with an explicit escape hatch.

> **⚠ Known client divergence — the server's contract above is not uniformly honored
> by the existing clients, and this is an open decision, not a bug in one specific
> direction.**
>
> - **The embedded `FileLayer::Chunk#undelete`** (shipped inside `chaim354/tinkerex-sync`,
>   consumed by `chaim354/tinkerex` as a gem) calls
>   `Sync::Trash.restore(user:, node_id:, to_root: true)` — **unconditionally true**,
>   matching what its own web-facing `TrashController#restore` action has always passed on
>   the chunk-backend branch (a browser's Restore button has no UI to ask "restore to
>   root?", so it would rather succeed there than surface a 500).
> - **The remote `FileLayer::ChunkRemote#undelete`** (`chaim354/tinkerex`,
>   `app/services/file_layer/chunk_remote.rb`) instead calls
>   `transport.post("/v1/trash/#{node_id}/restore", {})` — an **empty body**, so `to_root`
>   is absent and defaults to the server's own `false`. An orphaned node restored through
>   this adapter gets the strict `409 {"error":"parent_deleted"}` (mapped by
>   `FileLayer::ChunkRemote::Transport#interpret` to `FileLayer::UnsupportedOperation` — see
>   [§12](#12-reference-client-error-mapping)), not the permissive root-restore the embedded
>   adapter always gets for the identical user action.
>
> **Document the server's contract precisely** (default `false`, explicit opt-in via
> `to_root: true`, `409 parent_deleted` otherwise) and treat the two clients' disagreement
> about which value to send as an **open product question**, not something this document
> resolves. A Rust rewrite of the server should preserve the parameter and its default
> exactly as specified — the divergence is a client-side decision waiting to be made, not a
> server defect to paper over by changing the default.

**Non-commutative restore order, a direct consequence of the cascade in
[§8.8](#88-delete-v1nodesnode_id).** Because a directory delete tombstones its whole
subtree in one call, restoring a **child** before its **parent** with `to_root: true`
permanently nulls the child's `parent_node_id` — restoring the parent afterward does not
reunite them, since the child no longer points at it. Top-down restore (parent, then
children) preserves structure; bottom-up with `to_root: true` scatters a folder's contents
to the root irreversibly. Ordering restores is a caller responsibility; the server does not
sequence this for you.

**Undeleting an already-live node is not uniformly handled across every adapter that could
call this same server endpoint** (a fact about the two *host-side* `FileLayer` adapters
that both eventually call this one server action, not a divergence in the server's own
behavior): the server's `Sync::Trash.restore` itself is a clean, single, idempotent
success in this case (early-returns `[node, nil]`, `seq: null` in the response, no
mutation) — that is the one and only behavior this endpoint has. It's worth knowing the
same fact reads differently through `FileLayer::Share`/`FileLayer::S3`'s own *separate,
non-sync* undelete mechanism on the host side (`FileLayer::NotFound` there, since their
trash is a completely different bytes-on-disk mechanism) — but that is a host adapter
detail with nothing to do with this wire endpoint, mentioned only to head off confusing the
two.

**Pinned by:** `trash_flow_test.rb`'s "restoring an orphaned node returns 409 unless
to_root" is the direct scenario proving the server's default-`false` contract end to end
(create a dir, put a file under it, delete both, attempt restore without `to_root` → 409
`parent_deleted`, retry with `to_root: true` → 200 with `parent_node_id: null`). The client
divergence itself is confirmed by reading `app/services/file_layer/chunk.rb:497` (`to_root:
true`) against `app/services/file_layer/chunk_remote.rb:206` (`transport.post(...,  {})`)
directly, both in `chaim354/tinkerex`.

### 8.13. Locks

Best-effort, advisory, TTL-based (`Sync::Locks::TTL = 5.minutes`). A lock **never blocks a
commit** — it exists so *connected* clients can avoid colliding before they diverge; the
offline path skips it entirely and conflict detection
([§8.2](#how-finalize-decides-a-commit-is-a-conflict)) is the real safety net.

#### `POST /v1/nodes/:node_id/lock`

**Capability:** `syncable`. Acquire or refresh. **Always `200`**, even when another device
holds it — the client decides what to do with a `by_me: false` result, so there is no
distinct "denied" status.

```json
{ "node_id": "...", "held": true, "by_me": true, "device_name": "laptop",
  "expires_at": "2026-08-24T12:05:00.000Z" }
```

A concurrent-acquire race (two devices creating the row for the same node_id
simultaneously) is resolved by the DB's own unique index — the loser's `RecordNotUnique`
is caught **inside the service**, not surfaced as a `409`; it simply re-reads and reports
the winner's status.

#### `POST /v1/nodes/:node_id/unlock`

**Capability:** `syncable`. Release, only if the calling device is the holder (silently a
no-op otherwise — no error either way). Success — `200`: `{ "released": true }`.

#### `GET /v1/locks`

**Capability:** `syncable`. Every currently-active (unexpired) lock for the user.

```json
{ "locks": [ { "node_id": "...", "held": true, "by_me": false, "device_name": "desktop",
                "expires_at": "..." } ] }
```

**Pinned by:** `capability_gating_test.rb` covers the 501 case for all three, and the 200
case for `GET /v1/locks` specifically (in its "chunk mode is completely ungated" list —
note that list does **not** separately re-exercise `lock`/`unlock`'s 200 path, only their
501 path). `test/services/sync/locks_test.rb` covers `Sync::Locks` at the service layer,
including the race above. No dedicated HTTP-level happy-path test for `POST
.../lock`/`.../unlock` was found; both controller actions are thin one-line passthroughs
to the service.

### 8.14. `GET /v1/conflicts`

**Capability:** `syncable`. Unresolved conflicts (both sides' details), for a "which
version is current?" prompt. See ["How finalize decides a commit is a
conflict"](#how-finalize-decides-a-commit-is-a-conflict) (under [§8.2](#82-post-v1commitcommit_idfinalize)) for how a conflict is created.

```json
{ "conflicts": [
    { "node_id": "...", "name": "...",
      "current": { "version_id": "...", "size": 1048576, "created_at": "...", "device_name": "laptop" },
      "incoming": { "version_id": "...", "size": ..., "created_at": "...", "device_name": "desktop" } }
] }
```

`device_name` falls back to the literal string `"another device"` when the device row is
gone (e.g. deregistered since). An empty list is a genuine, honest "no unresolved
conflicts" here — unlike the `versions` gate's concern, an empty conflicts list on an
unsyncable deployment would also be a lie, which is exactly why this endpoint is gated
too.

**Pinned by:** `capability_gating_test.rb` (501 and the "ungated in chunk mode" 200 check);
`test/services/sync/conflicts_test.rb` at the service layer.

### 8.15. `POST /v1/nodes/:node_id/resolve_conflict`

**Capability:** `syncable`. Resolves **every** open conflict row for the node in one call
(N-way — a node can have several divergent incoming versions if more than two devices
diverged before any of them synced).

Two mutually exclusive request shapes:

- **Keep one side:** `{ "keep_version_id": "<required unless split>" }` — makes that
  version current; every other (both current-at-the-time and every incoming) side is
  discarded from the live tree (retained in version history, just no longer pointed to).
  Success — `200`: `{ "seq": ... }`.
- **Split (keep both):** `{ "split": true }` — the node's current content is left alone;
  **every** divergent incoming version becomes a new sibling file named `"<base> (conflict
  from <device> <YYYY-MM-DD HHMM>)<ext>"`, reusing its existing manifest (refcount bump
  only, zero new bytes). Success — `200`:
  `{ "split_node_id": "<first new sibling, kept for 2-way callers>",
     "split_node_ids": ["<every new sibling, in order>"], "seq": ... }`.

`split` is read via `ActiveModel::Type::Boolean` (`"true"`, `true`, `"1"` all count; a
missing/false value takes the keep branch, where `keep_version_id` is then required). Both
branches append changelog entries with **`op: "put"`** — one entry for the keep branch
(the node itself), one *per new sibling* for the split branch — the same overloaded op
described at the end of [§6](#6-data-model); there is no distinct `"resolve"` or
`"conflict_resolved"` op anywhere in the vocabulary.

Errors: no unresolved conflict for the node → `404 {"error":"not_found"}` (a
`RecordNotFound` raised with a specific message the client never sees — see
[§5](#5-the-generic-error-envelope)'s warning about this exact shape). A `keep_version_id`
that isn't actually one of this node's conflicting sides → `422 {"error": "version is not
part of this conflict"}` (an `ArgumentError`, verbatim message preserved this time).

**Pinned by:** `node_guards_test.rb` ("resolve_conflict with a version not part of the
conflict returns 422" — manufactures a real conflict via two devices racing a commit
against a stale base, then exercises the 422); `capability_gating_test.rb`;
`test/services/sync/conflicts_test.rb` for `keep`/`split` at the service layer, including
the N-way case.

### 8.16. `POST /v1/chunks/download`

**Capability:** `syncable`. Hydration: presigned GET URLs for a batch of chunk hashes the
client needs. **This is the entire read-side credential mechanism** — there is no bulk,
prefix-scoped, time-boxed "read token" anywhere in this API; every hydration request names
its hashes explicitly.

Request body: `{ "hashes": ["<hash>", "..."] }`. Success — `200`:
`{ "urls": { "<hash>": "https://..." } }` — **only for hashes the requester actually owns**
(a `chunks` row exists for `(user, hash)`); an unowned or malformed hash is silently
omitted from the response rather than erroring, so `urls` may be a strict subset of the
requested `hashes`. A malformed hash (not 64 lowercase hex chars) never reaches the
ownership check at all — filtered out first, defense in depth against building a storage
key from client-controlled junk. Batches over 10,000 hashes
(`Sync::V1::ChunksController::MAX_DOWNLOAD_HASHES`) are refused outright:
`422 {"error": "too many hashes (<n> > 10000)"}`.

**Pinned by:** `test/integration/v1/tenant_isolation_test.rb` ("chunk-download only mints
URLs for chunks the requester owns" — the clearest direct evidence, including asserting
the returned URL is scoped to the owner's own `chunks/<id>/` prefix); `node_guards_test.rb`
(malformed hashes silently yield no URL; over-cap → 422); `capability_gating_test.rb`.

### 8.17. Share links

Read-only, anonymous-redeemable capability links over exactly **one immutable version**.
Deliberately unrelated to any host's own "Share" storage backend naming — a share link
here is a URL token, full stop.

#### `POST /v1/share_links`

**Capability:** `versioned` (a link is version-scoped by construction — there's nothing to
freeze on an unversioned deployment). Authenticated (device token).

Request: `{ "node_id": "<required>", "version_id": "<required>", "expires_at": "<optional
ISO-8601-ish string, or omit for never>" }`. Resolves via
`user.versions.find_by!(node_id:, version_id:)` — scoped to the caller, so naming a
version that exists but belongs to a different user is indistinguishable from naming one
that doesn't exist: `404 {"error":"not_found"}` either way (no ownership leak).

Success — `201 Created`:

```json
{ "id": 17, "token": "<raw token, shown exactly once>", "version_id": "...", "expires_at": null }
```

**The raw token is returned only here, at creation.** Only its digest is ever persisted
(`Sync::ShareLink#token_digest`); there is no "show me my link again" endpoint — the
response above also deliberately omits `node_id`, even though the underlying row stores
it. **There is no `GET /v1/share_links` to list a user's own links at all** — the drawer
defines only `create`/`destroy`; a caller that doesn't record the `id` (needed to revoke
later) and `token` (needed to hand out) at creation time has no way to recover either
afterward.

#### `DELETE /v1/share_links/:id`

**Capability:** none (unlike `create`, since revoking never needs the `versioned`
capability to be meaningful — a link that exists at all can always be revoked).
Authenticated; scoped to the caller's own links (`current_user.share_links.find`), so
another user's link id → `404`, never a `403` (no existence leak). Success —
**`204 No Content`** (no body — the one endpoint in the JSON family that isn't JSON on
success).

#### `GET /v1/share/:token`

**Not capability-gated** (see [§7](#7-capability-gating)). **No device token** — the
capability is the token itself, re-validated (not revoked, not expired) on every request.

Success — `200`: `{ "name": "...", "node_id": "...", "version_id": "...",
"manifest": [{"hash": "...", "offset": 0, "length": ...}] }`. `manifest` is the frozen
version's full ordered chunk list — read fresh from `manifest_chunks` on every request
(liveness and scope are always re-evaluated server-side, never cached in the token).
Unknown, expired, or revoked token → `404 {"error":"not_found"}` — no status distinguishes
"never existed" from "expired" from "revoked," on purpose (an anonymous caller learns
nothing more than "that token doesn't work").

#### `POST /v1/share/:token/download`

**Not capability-gated.** Same auth (none but the token) and same liveness re-check.
Success — `200`: `{ "urls": { "<hash>": "https://..." } }` — **every** hash in the frozen
manifest, unconditionally (unlike the authenticated `/v1/chunks/download`, there is no
partial/omitted-hash case here, since the capability's hash set already **is** exactly the
version's manifest). Presigned against the **owner's** keyspace
(`chunks/<owner_id>/<hash>`) — the redeeming stranger never learns the owner's identity
beyond what the URL's path segment already reveals. Same `404` on a dead token.

**Pinned by:** `test/integration/v1/share_links_test.rb`, thoroughly — the full
create→view→download happy path, ownership enforcement on create (404 for a
non-owned version), unknown-token 404 on both anonymous endpoints, and the full
revoke→dead-immediately lifecycle including cross-owner revoke denial (404, not 403).
`capability_gating_test.rb` additionally confirms the anonymous redeem side stays 404 (not
501) even with no chunk store configured at all.

### 8.18. Local blob tier: `PUT`/`GET /v1/chunks/blob/:user_id/:hash`

**Not part of the JSON family — see [§4](#4-two-wire-families).** These two exist only to
give the `local` chunk backend (`STORAGE_BACKEND=local`) a real HTTP data plane on a
single self-hosted box with no external object store — the same role S3/R2 plays in
production, colocated instead of external. On any other `STORAGE_BACKEND`, both routes
`404` unconditionally regardless of signature validity (`ensure_local_backend`'s
`before_action` checks `Sync::Storage::ChunkStore.current.is_a?(LocalChunkStore)` first,
before signature verification even runs).

**Authorization is an HMAC signature in the query string, never a bearer token** —
`?exp=<unix timestamp>&sig=<hex hmac>`, where
`sig = HMAC-SHA256(Rails.application.secret_key_base, "<user_id>\n<hash>\n<exp>")`. This
mirrors exactly how a presigned S3 URL carries its own auth — the key is user-scoped by
construction (the path itself embeds `user_id`), so cross-user access requires forging the
signature, not merely guessing a URL.

`PUT` — request body: raw bytes, `Content-Type: application/octet-stream`, capped at
64 MiB (`Sync::V1::Chunks::BlobController::MAX_BYTES` — generous; FastCDC chunks are
KB-scale in practice). Success: **`200 OK`, empty body** (`head :ok`). Over the cap:
`413 Payload Too Large`, **plain-text body** `"chunk too large"` — not JSON.

`GET` — success: `200`, `Content-Type: application/octet-stream`, `Content-Disposition:
inline`, raw bytes. Absent chunk (valid signature, nothing stored at that key):
`404`, empty body.

Both: tampered or expired signature → `403 Forbidden`, empty body (`head :forbidden`) —
checked via `ActiveSupport::SecurityUtils.secure_compare`, so this is a constant-time
comparison, not a source of a timing oracle.

**Pinned by:** `test/integration/v1/chunk_blob_test.rb`, thoroughly — round-trip byte
fidelity (including raw non-UTF8 bytes), absent-chunk 404, tampered-signature 403,
expired-URL 403, and the backend-mismatch 404 (signed correctly, but the active store
isn't `local`).

---

## 9. Realtime notifications (ActionCable)

On every commit, mutation (mkdir/move/delete/symlink/restore), conflict, or trash-restore,
the server broadcasts a coarse nudge — **not** a diff, just "something changed, go pull":

```
{ "head_seq": 43 }
```

to a per-user stream (`Sync::LibraryChannel`, `stream_for current_user`). A device
subscribed to this stream, on receiving a nudge, is expected to call `GET
/v1/changes?since=<its own cursor>` — the nudge itself carries no information the pull
doesn't already provide, it only signals *when* to bother pulling. **The committing
device's own nudge is a no-op for it** — its cursor already advanced from the commit's own
response.

**Connection auth:** the WebSocket URL carries the device token as a query parameter
(`?token=<device_token>`), read by the host's `ApplicationCable::Connection#connect`
(`identified_by :current_user`; `Device.authenticate(request.params[:token])`, rejecting
the connection outright on failure) — the same credential as every HTTP request, just
carried differently since a WebSocket handshake has no custom-header convenience for most
client libraries.

**Bulk host-side operations coalesce their nudges.** A sweep that mutates many nodes for
one user (e.g. this app's own project-folder auto-filing) wraps its writes in
`Sync::LibraryChannel.batch(user) { ... }`, which collapses every nudge inside the block
into a single one carrying the highest `seq` reached — each individual mutation still
takes its own lock and writes its own changelog entry; only the *notification* is
coalesced, not the writes themselves.

**This channel is a latency optimization, not a correctness requirement, and it is not
part of what makes two devices converge.** A device that missed every nudge (disconnected,
dropped a message, or talking to a server implementation that never built this channel at
all) converges identically by polling `GET /v1/changes` on its own schedule — the pull
endpoint is the authoritative mechanism; the push is purely "pull sooner." A from-scratch
Rust server implementation is free to replace Action Cable's own wire protocol (a
Rails-specific subscription/ping/message framing this document does not attempt to
fully specify) with any transport that delivers the same `{head_seq}` semantics — or, as a
first cut, to omit it entirely and rely on client-side polling, at a latency cost but with
no correctness cost, while it's built.

---

## 10. Chunk storage & presigning

`Sync::Storage::ChunkStore.current` selects one implementation via `STORAGE_BACKEND`
(`memory` in test; `s3` everywhere else by default; `local` opt-in):

| Backend | `presign_put`/`presign_get` | Bytes ever touch this process? |
|---|---|---|
| `s3` (production) | Real S3/R2 presigned URLs, SigV4-signed | No — direct client ⇄ bucket |
| `local` (self-host, no external object store) | `https://<host>/v1/chunks/blob/<user>/<hash>?exp=...&sig=...` — this API's own two blob endpoints ([§8.18](#818-local-blob-tier-putget-v1chunksblobuser_idhash)) | **Yes, deliberately** — this is the one sanctioned exception to "bytes never flow through the control plane," and it exists only so a single box needs no external S3-compatible service to exercise the full presigned round trip |
| `memory` (tests only) | Fake `memory://` URLs no real HTTP client can use | N/A — control-plane behavior only, never a real byte transfer |

The `presign_put`/`presign_get` **contract**, regardless of backend: a time-boxed URL
(`expires_in` in seconds, default 900s for PUT / 3600s for GET) scoped to exactly one
`chunks/<user_id>/<hash>` key, such that possessing the URL is sufficient and necessary
authorization for that one object. A Rust implementation is free to choose any backend
that satisfies this — S3-compatible presigning, a bespoke HMAC scheme matching the
`local` tier above, or something else entirely — as long as `POST /v1/commit`'s
`put_urls` and `POST /v1/chunks/download`'s `urls` keep returning URLs a plain HTTP client
can PUT/GET without any further credential.

**One narrow non-presigned exception exists server-side, and it is not part of the wire
protocol at all:** `Sync::Storage::ChunkStore#put(user_id, hash, bytes)` is a direct
server-side write, used only when the *server itself* generates content with no client to
presign for (in `chaim354/tinkerex`, addon-generated output —
`Maker::Addons::LibraryOutput`). No endpoint in this document exposes it; it is a host
integration detail, mentioned only so its absence from the endpoint list above isn't
mistaken for an oversight.

---

## 11. Refcounts and GC (not part of the wire)

Every chunk row carries a `refcount`, bumped by `+1` whenever a manifest that references it
is newly committed, restored, or conflict-split into a sibling, and dropped only when a
**version** (not a node) is pruned by a retention policy — deleting a node only tombstones
it; its versions and their chunks are untouched, which is what makes trash/undelete and
version restore both free of re-upload. **No endpoint in this document exposes refcounts,
retention, or garbage collection directly** — `Sync::Gc` (`prune_version!`,
`apply_retention!`, `sweep_orphans!`) runs as a background job, not a request handler. It
is mentioned here only so an implementer understands *why* restore/split are cheap
(chunks already exist) and why deleting a node is instant regardless of its content size
(nothing is actually removed) — not because a Rust rewrite needs to replicate its internal
mechanics to be wire-compatible. What the wire *does* depend on: a version, once created,
is never silently invalidated out from under a client holding its `version_id` — a client
that has captured a `version_id` (from a commit response, a changes entry, or a versions
list) can always name it later (`restore`, a share link) unless a retention policy has
explicitly pruned it, which is an operator/policy decision, never automatic.

---

## 12. Reference client error mapping

`FileLayer::ChunkRemote::Transport` (`chaim354/tinkerex`,
`app/services/file_layer/chunk_remote/transport.rb`) is the one existing client for the
standalone-server topology, and its error mapping is worth reproducing here as a **de
facto interop contract** — a Rust server that wants to work with this exact client should
keep matching it (a from-scratch client is, of course, free to map differently):

| Server response | Client-side result | Why |
|---|---|---|
| Network error, timeout, connection refused | `FetchError` (retryable) | The file is fine; the network or server is not. |
| `401` / `403` | `FetchError` (retryable), **deliberately not terminal** | A rejected device token is an operator condition (expired/rotated/revoked credential), not a statement about the file — answering as if the file is gone would be a lie. |
| `404` | `NotFound` (terminal) | The node is genuinely gone. |
| `409` / `422` | `UnsupportedOperation` (terminal) | A clobber, a cycle, a refused name — never succeeds on retry, which is exactly what distinguishes it from `FetchError`. |
| `501` | `UnsupportedOperation` (terminal) | The server gated the verb — terminal for *this* deployment, same as any other backend refusing a capability it structurally lacks. |
| A body with `"error": "chunks_missing"` | `ChunksMissing`, carrying the `missing` array | Parsed specially, ahead of the generic `422` mapping above, specifically so the `missing` hashes aren't discarded — the whole point of that response shape is telling the caller exactly what to re-upload. |
| Any other non-2xx | `FetchError` | Unrecognized — treated as transient rather than asserting a meaning this table doesn't know. |

A body that fails to parse as JSON is not itself treated as an error by this client — the
HTTP status has already been read by that point; a non-JSON body (a proxy's own error
page) only degrades the *message text*, never the mapped exception class.

---

## 13. Things left genuinely unspecified

Stated plainly rather than glossed over, per the standard this document holds itself to —
a sentence that can't survive "could someone implement this from it" is either fixed above
or named here instead:

- **`parent_node_id` carries no referential-integrity check anywhere in the write path** —
  not a DB foreign key (`db/schema.rb` only adds an FK from `nodes` to `users`, none for
  `parent_node_id`), not a model validation, not a controller-level existence check.
  `mkdir`, `symlink`, a content commit, and `move` all accept an arbitrary string as a
  parent. The only structural guard that exists at all is the **cycle** check (a proposed
  new parent can't be the node itself or its own descendant) — which, walked from a
  nonexistent parent, simply terminates immediately as "no cycle found" and lets the
  operation through. A node whose declared parent doesn't exist becomes unreachable from a
  root-down tree walk but still appears in `GET /v1/changes`/`GET /v1/search`. Whether a
  future revision should validate this is unresolved; today's behavior, exactly as
  observed in the code, is "unchecked."
- **Neither `GET /v1/changes` nor `GET /v1/tree` returns an explicit "more pages" flag.**
  Both use the same implicit convention (page while the array comes back full/non-empty),
  which every reader of this document should preserve exactly rather than "improving" with
  an explicit flag — that would be an additive wire change against every existing client's
  assumption, however reasonable it looks in isolation.
- **`mtime`'s unit (nanoseconds since epoch) is an observed client convention, not a
  server-enforced or server-documented contract anywhere in the code.** The column is an
  opaque `bigint`; nothing validates, parses, or compares it server-side beyond storing and
  echoing it back.
- **The `to_root` divergence in [§8.12](#812-trash--undelete-and-the-to_root-divergence)
  is an explicitly open product decision**, not resolved by this document and not this
  document's to resolve.
- **The Action Cable wire protocol itself** (subscription handshake, ping cadence, message
  framing) is Rails/Action-Cable-specific machinery this document does not attempt to fully
  specify — [§9](#9-realtime-notifications-actioncable) states the *contract* (`{head_seq}`
  to a per-user stream, latency-only) rather than the transport's byte-level protocol.
- **A malformed `expires_at` string on `POST /v1/share_links`** — its exact failure mode
  (silently nulled, a validation error, an uncaught `TypeError`) was not verified against a
  running server for this revision and is not asserted above.

---

## 14. Deferred (explicitly out of scope for v1)

- **Selective sync** (per-device folder subscriptions) — every device still mirrors the
  full tree; only content hydration is on-demand.
- **Write sharing / multi-user workspaces ("Spaces")** — today's share links are
  strictly read-only, version-scoped, and never re-key the chunk store; a shared link
  reads from the *owner's* keyspace under a scoped capability. Full read/write sharing
  with its own keyspace is planned, not built.
- **At-rest chunk encryption** — deliberately last; presigning and storage today assume
  plaintext-at-rest object storage.
- **Any maker-app metadata** (projects, inventory, BOM, previews) — a separate layer in
  the host application entirely, out of scope for this document and for the engine itself.

---

## 15. Where to look next

- `chaim354/tinkerex-sync`'s `crates/tinkerex-sync` — the server, and its README (subcommands,
  env, the two stores); `src/http/mod.rs` holds the route table `tinkerex-sync routes` prints.
- `chaim354/tinkerex-sync`'s Ruby `lib/tinkerex_sync/v1_routes.rb`, `app/controllers/sync/v1/*.rb`,
  `app/services/sync/*.rb` — the source this document was derived from, deleted in Phase 6;
  `git show 36bb82e:<path>` there for anything this document doesn't cover.
- `chaim354/tinkerex-sync`'s `conformance/` — the corpus this document points at rather than
  duplicates. Check whether `conformance/scenarios/*.yml` exists yet before trusting this
  document's prose over a recorded scenario.
- `chaim354/tinkerex-sync`'s `README.md` as of `36bb82e` — the standalone `host/` app, what a
  host had to supply (`TinkerexSync::HOST_MODELS`, Action Cable adapter, `limits_concurrency`),
  and the 2026-08-22 end-to-end verification.
- This repo's `docs/architecture-sync-engine.md`, `docs/SYNC_SERVER.md`, `docs/STATUS.md` —
  broader architecture, deployment, and the canonical, dated record of what's built and
  what's still open (this document deliberately does not narrate history — see its own
  framing note).
- This repo's `CLAUDE.md` §14a/§14j — the *host*-side adapter contracts
  (`FileLayer::Chunk`, `FileLayer::ChunkRemote`) that consume this wire protocol, including
  several invariants (the two-tombstone-kinds distinction, the `write` verb's permanent
  refusal, the `undelete`-of-live-node divergence between adapters) that are host concerns
  layered on top of this protocol rather than part of the protocol itself.
