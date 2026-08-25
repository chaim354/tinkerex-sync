# CLAUDE.md — tinkerex-sync

Project context for an AI coding agent (Claude Code) and human developers.

> ## READ THIS FIRST: this file was inherited, not audited
>
> **Everything below was extracted from `chaim354/tinkerex` CLAUDE.md on 2026-08-25** and has
> **NOT been verified against this repository's current code.** It was written while the sync
> engine was a *gem embedded in the maker app*, so it describes that arrangement — a host that
> might configure a share/s3 backend, capability seams built for that host, a dummy app standing
> in for it. This repo has moved on: it has its own host app under `host/`, a
> `POST /v1/admin/libraries` provisioning endpoint, a conformance corpus, and its own deploy.
> None of that is described here yet.
>
> **Treat every rule below as a lead, not as ground truth.** Verify against the code before
> relying on one — that is this project's own standing rule (`probe over argument`), and it
> applies with special force to a document that arrived by relocation. As each area is verified,
> rewrite it in place and delete this warning for that section.
>
> What IS known good, because it was checked from the maker-app side on 2026-08-25:
> - This repo is **not a dependency of `tinkerex`**. No gem, no `Gemfile.lock` pin, no
>   cross-repo schema guard. The two are coupled by the **wire** only.
> - The maker app is a **client** of eight endpoints here: `/v1/tree`, `/v1/changes`,
>   `/v1/commit`, `/v1/commit/:id/finalize`, `/v1/chunks/download`, `/v1/nodes`,
>   `/v1/trash/:id/restore`, and `/v1/admin/libraries`.
> - What checks that coupling is `bin/ci test-chunk-remote` **in the maker app** (it boots this
>   repo's host app via `bin/sync-server` and runs the full maker suite against it), plus this
>   repo's own conformance corpus.
> - This repo runs as the **`sync` Kamal accessory**, not a service — that is what gives it the
>   fixed container name `tinkerex-sync`, the stable network alias the maker app puts in
>   `CHUNK_REMOTE_URL`. A Kamal *service* gets a per-deploy `<name>-<sha>` name, so
>   `http://tinkerex-sync:3000` does not resolve to one (measured: 000). A standalone service
>   deployed from this repo's own `deploy.yml` **collides** with that accessory on the
>   `service=tinkerex-sync` label — pick one shape per box.

---

## 1. What this is

A local-first file sync engine, as a mountable Rails engine (`isolate_namespace Sync`) plus a
host app under `host/`. Files are split into **content-defined chunks (FastCDC)**,
content-addressed and deduped. A commit is an **immutable version** pointing at a chunk manifest;
devices converge by pulling a **per-user changelog**.

**Chunk bytes move client-to-storage over presigned URLs and never through Rails** — the engine
is a control plane and a URL signer, not a data path. That is the single most important
invariant here, and it is the one a "just stream it through" change quietly breaks.

Licensing: **permissive only (MIT/Apache/BSD)**. Avoid GPL/AGPL in anything depended on or
shipped. FastCDC is MIT, SQLite public domain, this engine MIT.

---

## 2. Architecture

> **A remote-mounted filesystem does NOT work over the WAN.** rclone/JuiceFS mount = synchronous
> metadata round-trips → ~1 s/file (measured). Every production system uses **local metadata +
> async sync + on-demand hydration**. That pivot is the whole reason this architecture exists.
> Do not go back to a remote mount.

- Each device backs its filesystem with a **local SQLite tree** → `stat`/`readdir`/`open` are
  instant; **the WAN is never in the metadata path.**
- This server is the **source of truth**: tree + immutable versions + a per-user **changelog**.
  Devices stay consistent by pulling entries where `seq > cursor`.
- Versioning and dedup are native: a version is a content-addressed manifest sharing chunks.
  **Keep versions** (don't prune) so restore always works; GC only sweeps refcount-0 chunks.

**Data model:** `users(head_seq)`, `devices`, `nodes(node_id, parent, name, kind,
current_version, deleted)`, `versions(parent chain)`, `manifest_chunks`, `chunks(refcount)`,
`changelog_entries(seq)`, `pending_commits`, `conflicts`, `file_locks`, `share_links`. Stable
cross-device ids are string UUIDs.

**Three channels:** HTTPS API (control), ActionCable (the "pull" nudge, `{head_seq}` on commit),
direct to storage (chunk bytes via presigned URLs).

- **Push:** `export_tree` → per file `commit` (begin → upload missing chunks → finalize); dirs
  via `mkdir`. Server appends one changelog entry, bumps `head_seq`, broadcasts.
- **Pull:** changelog delta since cursor → `apply_remote` into local SQLite → dehydrate changed
  placeholders. The delta is **paged** and full-resyncs when the cursor is below the server's
  `oldest_seq` (pruned-gap detection).
- **Hydrate:** on read, fetch missing chunks via presigned GET → local cache.
- **Conflict detection** (replaced v1 last-writer-wins): each commit sends its `base_version_id`;
  if it is no longer current the server records a **conflict** (both versions kept) instead of
  silently dropping an edit. A base that IS current is a clean fast-forward.

Normative wire spec: `docs/sync-protocol.md` in the maker-app repo (`chaim354/tinkerex`) — it
should probably move here.

---

## 3. Security

- **Tenant = user** (one library, that user's own devices). Isolation is ordinary Rails
  `user_id` scoping.
- **A client holds only a device token** (256-bit, SHA256-digested at rest). No storage
  credentials — it gets short-lived, per-object **presigned URLs**, SigV4-signed for a per-user
  key `chunks/<user>/<hash>` (untamperable → cross-user chunk access impossible; storage and
  dedup are per-user). `/v1/chunks/download` additionally only mints URLs for chunks the
  requester owns.
- **`POST /v1/admin/libraries` is gated by `SYNC_ADMIN_TOKEN`**, an operator credential a device
  token can never satisfy. This is what lets the maker app provision a per-user library lazily.
  Both sides must resolve the SAME 1Password item or the far side answers 503.
- **Server presigning is local** (HMAC) — chunk URLs are verifiable without the storage being
  reachable.

---

## 4. Invariants (inherited — verify before relying on one)

Each line below cost a real bug **in the maker app's repo, while this engine lived there**.
Section numbers in the original (`§14a`, `§14e`, `§14j`) are given so the history is traceable.

### 4a. The `FileLayer::Chunk` adapter (`app/services/file_layer/chunk.rb`) — was §14a

This adapter is the sanctioned in-process door onto the engine. The maker app ships the
*factory* (`FileLayer.build`); this repo ships this *adapter*.

- **`Chunk` ANSWERS the four metadata verbs and refuses only the BYTE write.** `mkdir`/`move` →
  `Sync::Mutation.apply`, `undelete` → `Sync::Trash.restore`, and `delete` →
  **`Sync::SubtreeDelete.call`** — **never** `Sync::Mutation.apply(op: "delete")`, which
  tombstones only the node it is handed and **orphans every descendant**. That trap is the one
  thing this bullet exists to protect. **`write` still refuses, and must**: it takes an IO, and a
  server-side byte write would push bytes through Rails. Chunk's own upload is the port's
  `begin_upload`/`finalize_upload` pair instead.
- **`begin_upload`/`put_chunk`/`finalize_upload` are port verbs, and none is the byte-taking
  `write`.** `begin_upload` returns presigned PUT URLs for whichever chunks the store is missing
  and the caller PUTs straight to object storage. **`put_chunk` is a port verb implemented
  per-adapter, not one shared call** — `FileLayer::Chunk#put_chunk` writes the embedded store
  **in-process**, because on embedded chunk a presigned URL for the memory/local store can point
  BACK AT RAILS ITSELF, and a server-side PUT to it would be a **loopback call into the same Puma
  pool** (a recorded reentrancy bug: 14–24 second stalls, outright 404s). Only the adapter knows
  which situation it is in.
- **AN ORPHANED RESTORE IS REFUSED — and this REVERSED an earlier rule.** The old rule had
  `Sync::Trash.restore(to_root: true)` NULL `parent_node_id` when the parent is itself
  tombstoned, reparenting an orphan to the library ROOT rather than raising. Because `delete`
  cascades a whole directory in one call (`Sync::SubtreeDelete`), restoring a CHILD before its
  PARENT is the **mainline** case, and a bottom-up restore permanently scattered that folder's
  contents to the root, irreversibly. **A refusal is recoverable — restore the folder, then the
  file; a scatter is not.** `Chunk#undelete` therefore takes `Sync::Trash.restore`'s own default
  (`to_root: false`), raising `Sync::Trash::ParentDeleted`, mapped to `UnsupportedOperation` with
  a message naming the ACTION a user can take.
  **`Sync::V1::TrashController` — the DEVICE-facing API — keeps a caller-supplied `to_root:`,
  deliberately.** Do not "fix" it into agreement: a device client can ask for the strict 409 and
  prompt its own UI, where a browser Restore click has no such prompt.
- **`Sync::Trash.restore` has no `destination_vacant!` check**, so a revive can land two live
  nodes sharing one `(parent, name)` where share and s3 both refuse that clobber. Pre-existing,
  recorded rather than closed.
- **Undeleting an ALREADY-LIVE node is an idempotent success here** (`Sync::Trash.restore`
  early-returns) but `NotFound` on share/s3. Structural, not arbitrary — unifying it means either
  raising about a file that IS restored, or claiming a byte move that never happened.
- **`Chunk#download`'s `is_a?(S3ChunkStore)` is deliberately NOT `presignable?`** — memory and
  local stores presign to URLs **Rails itself serves**, so redirecting sends the browser back
  through us. The `chunks.size == 1` half is load-bearing too: a redirect names ONE object, so
  redirecting a multi-chunk file hands the browser its first chunk with a 200 and the right
  filename — **silent truncation**.
- **`Sync::Commit.begin` validates the manifest exhaustively and the name NOT AT ALL**, and
  `Node` validates `name` for presence only. So `"../../escape.txt"` and reserved names like
  `.trash` / `.maker-tmp-*` create live nodes here where share/s3 refuse them. The maker app
  closes this **at its own doors** (`Library::ReservedNames`, `Maker::MoveNode.valid_leaf_name?`)
  rather than adding a third copy in this adapter. **A device push through a real mount reaches
  `Sync::Commit#finalize` directly and gets no such check** — macOS mounts push `.DS_Store` nodes
  through it by design.

### 4b. Sequencing, refcounts and GC — was §14e

- **`next_seq!` must be the FIRST statement** in `Sync::Commit#finalize` / `Mutation#apply` /
  `Restore` / `Conflicts` / **`SubtreeDelete`** — five callers, and the cascade is the one with
  the most to lose, since it takes a seq PER NODE. Otherwise concurrent commits deadlock on a
  `FOR KEY SHARE`→`FOR UPDATE` lock upgrade. **A statement-mode pooler breaks it** — a boot guard
  refused to start behind one (`postgres_pooler_check`).
- **EVERY REFCOUNT WRITE GOES THROUGH `Sync::Gc.touch_refcounts!`, never a bare `update_all`** —
  `update_all` does not maintain timestamps, and `Gc.sweep_orphans!`'s grace window filters on
  `updated_at`. With the column only written at `insert_all` time, the filter tested the chunk's
  **CREATION age, not its ZEROING age**, so for every real chunk the promised protection **did
  not exist**. Four sites (`gc`, `commit`, `restore`, `conflicts`).
  Two ordering rules go with it: **`sweep_orphans!` deletes compare-and-swap**
  (`where(id:, refcount: ..0).delete_all == 1` before the byte delete), because it takes no user
  lock and its batch is a snapshot a concurrent `Commit#finalize` can re-reference **0 → 1 while
  uploading nothing** — leaving a live version pointing at a chunk with no row and no bytes; and
  **`prune_version!` is claim-then-decrement** (delete the version row, decrement only if it
  removed 1), so two overlapping retention passes cannot decrement twice for one removal.
  The `WHERE refcount > 0` guard prevents a NEGATIVE refcount, which was never the bug.
  **Failure mode throughout: silent permanent data loss**, managed/tiered only (`keep_all` never
  decrements).
  **Beware the test shape that hid it** — every sweep test hand-set `updated_at` via
  `update_column`, and the "within grace" one used a chunk created moments earlier, so it passed
  either way.
- **`share_links` is the engine's, and `Sync::Gc` is why.** `Sync::Gc.apply_retention!` reads
  `share_links` to protect versions live links point at. **Split the two and nightly retention
  silently destroys the bytes behind URLs users have already sent to other people** — no build
  break, no red test. Share links need a real `versions` row, so they cannot exist on share or s3
  at all.

### 4c. Engine structure — was §14j

- **`isolate_namespace Sync` sets `table_name_prefix` to `sync_`**, which would make every model
  look for a `sync_versions` table that does not exist. The override must be defined **BEFORE**
  `isolate_namespace` runs, because that method's own `on_load(:active_record)` hook re-defines
  it later in boot and clobbers a lexically lower one regardless of position.
  **`Sync::Version.table_name` must read `"versions"` — check it, do not assume it.**
- **THE ENGINE OWNS ITS ROUTES AS A DRAWER, NOT A MOUNT.** `Sync.draw_v1_routes(mapper)` lives in
  `lib/tinkerex_sync/v1_routes.rb`; a host calls it once inside its own `namespace :v1`.
  **`mount Sync::Engine` cannot express this**: the sync paths are not a contiguous block under a
  prefix of their own, they are INTERLEAVED with a host's inside one namespace, and a mount owns
  an entire prefix. Introducing a `/v1/sync/` prefix to make a mount possible would break every
  deployed desktop client. **NOT at `config/routes.rb`** — `Rails::Engine` reserves that path and
  evaluates it itself, so the drawer loaded twice there. Guarded by a test that asks the DRAWER
  what it defines rather than hard-coding a list.
- **THE ENGINE SHIPS THE BASE CONTROLLER AND A HOST INHERITS IT, NEVER THE REVERSE.** An engine
  inheriting a host class cannot load without that specific app, which defeats shipping it.
- **THE ENGINE PUBLISHES; THE HOST SUBSCRIBES (`Sync::Hooks`).** `V1::CommitsController#finalize`
  once called the maker app's `Maker::Previews::Enqueue` and `Maker::ProjectIntakeJob` directly —
  host business logic an engine cannot require and still run standalone. Three properties, each
  load-bearing: it fires **after** the commit transaction commits, a **raising subscriber never
  fails the commit**, and a host that **registers nothing still works**.
- **THE ENGINE NAMES NO HOST CONSTANT.** `Sync::V1::CapabilityGate` and
  `Sync::V1::StashRequestBaseUrl` ask `Sync.capability_available?` /
  `Sync.capability_unavailable_message` — `mattr_accessor`s defaulting to **"available,
  always,"** the correct permanent answer for a bare mount (this engine IS the sync engine; the
  capability question exists only because a HOST can configure a share/s3 backend that lacks
  versions or a changelog). A host wires them in an initializer.
- **HOST OBLIGATIONS UNDERCOUNTED, AND ONLY BOOTING FOUND IT.** Beyond `User`/`Node`/`Device`, a
  host must supply `::ApplicationRecord`, `::ApplicationJob`, `::ApplicationCable::Channel` — and
  **`limits_concurrency`**, which `Sync::RetentionJob` calls and which is **solid_queue's
  extension, not core ActiveJob**. A gemspec comment claiming "engine jobs are plain ActiveJob"
  was wrong; two of three are.
- **`dependent: :destroy` CONSTANTIZES; a string `class_name:` does not save you.** A host's
  `User` declaring `Sync::` associations when the engine is absent made an ordinary
  `user.destroy` raise `Missing model class Sync::Version` — **and nothing at boot showed it.**
- **`recurring.yml` needs `command:`, not `class:`, for engine jobs.** Solid Queue resolves a
  `class:` at load and reads ONE file with no merge mechanism, so any gate has to live in the
  entry.
- **A GUARD THAT SKIPS ON THE THING IT ASSERTS IS VACUOUS.** A boot test that skipped when
  `defined?(Sync)` meant the mutation which loaded the engine skipped every test and reported
  **success**. Skip on whether the leg was **invoked**, so absence is the claim rather than the
  precondition. Found by mutation-checking, not by reading.
- **A GUARD THAT SCANS A DIRECTORY DIES SILENTLY WHEN THE DIRECTORY LEAVES.** Both engine-side
  architecture guards were `assert_empty offenders` over a glob of `engines/tinkerex-sync/**`;
  extraction made that glob `[]`, which satisfies `assert_empty` perfectly, and "the sync engine
  never reaches into the maker layer" went on **passing over nothing**. They live here now, beside
  a third that asserts the file list is **non-empty** before the other two are trusted.
  **Do not rebuild them in the maker app against an installed copy** — a guard reading a vendored
  copy reports on whatever revision is pinned, so it goes green on a stale pin.
- **THE DUMMY HOST IS THE ONLY THING THAT PROVES ANY OF THIS.** Everything above is static
  analysis; `test/dummy` actually boots the engine in a process that has never loaded a maker
  layer.

---

## 5. Working agreements

- **Permissive licenses only** (§1); check new deps.
- **Keep bytes out of Rails** — presigned URLs, control plane only. This is the invariant most
  worth defending here.
- **Content-addressed chunks + immutable versions everywhere; keep versions** for restore.
- **Adapter-agnostic code** (SQLite + Postgres) with no PG-only SQL in the hot path.
- **MUTATION-CHECK EVERY GUARD YOU WRITE.** After a test that exists to *forbid* something goes
  green, break the thing it guards and confirm it goes **RED** — then restore. A guard that has
  never failed has not been shown to work. The dominant failure mode in this project's history is
  **a green suite over something that never worked**; every time someone did mutation-check, it
  paid immediately.
  **A TIMESTAMP COMPARED AT `.to_i` IS A GUARD THAT USUALLY CANNOT FAIL** — `.to_i` is whole
  seconds, and the row you are asserting about was written in the same second as the thing you
  fear overwrote it. Separate the two events in time, or assert a **content** column that is nil
  until something writes it.
- **A FAKE THAT SHARES THE CODE'S MISUNDERSTANDING CONFIRMS IT.** A `FakeS3` decoding
  `copy_source` with `CGI.unescape` while the adapter encoded with `CGI.escape` were exact
  inverses — **79/80 tests green over silent permanent data loss** on any filename with a space.
  **Assert the WIRE format, not the round-trip.**
- **Prefer a probe over an argument.** A final whole-branch review once found five real bugs of
  which four were already recorded as unreachable, deferred, or verified — the contribution was
  *probing*, not thinking.
- **The suite being green is not evidence a guard works** if the guard's precondition is never
  established in test. Drive the real request.

## 6. Cheatsheet

```sh
bundle install && bundle exec rake test

# Boot the host app (the maker app's bin/sync-server does this too, on $SYNC_PORT, default 3002)
cd host && bin/rails db:prepare && bin/rails server

# Real S3/SeaweedFS chunk storage (presigned PUT/GET). THESE ARE THIS REPO'S env vars —
# setting them on the maker app does nothing at all.
STORAGE_BACKEND=s3 CHUNK_ENDPOINT=http://192.168.1.8:8333 CHUNK_BUCKET=my-bucket \
  CHUNK_REGION=us-east-1 CHUNK_ACCESS_KEY_ID=admin CHUNK_SECRET_ACCESS_KEY=secret

# SYNC_VERIFY_FINALIZE=0: finalize's verify-the-bytes-landed check defaults ON, but the client
# integration suites move chunk bytes through SharedDirIO, not this server's store — so the
# server cannot see them.
```

**Deploy:** this repo runs as the **`sync` Kamal accessory** on the maker app's box (see the
warning at the top of this file for why accessory-not-service is load-bearing). It is a **second
database on that box**, known to the maker repo's backup scripts as `sync`:

```sh
bin/backup-db sync                                   # run from the maker app repo
bin/restore-db sync <archive> --into rehearsal --yes
```

**AN ACCESSORY HAS NO PROXY REGISTRATION UNLESS GIVEN ONE.** `sync` declares no `port:` and no
`proxy:` — correct, since only another container on the kamal network talks to it — but that
breaks any tool probing health by Host header. Probe from INSIDE it:
`docker exec tinkerex-sync curl localhost:3000/up`.

## 7. Related repos

| repo | role |
|---|---|
| `chaim354/tinkerex` | The **maker app** — projects, inventory, model library, addons. A CLIENT of this server via its `FileLayer::ChunkRemote` adapter (`LIBRARY_BACKEND=chunk_remote`). Owns `docs/sync-protocol.md`. |
| `chaim354/tinkerex-client` | The **Rust crates + Tauri desktop app** — `fs-provider`, the per-OS mounts, `sync-client`, `sync-engine`. Syncs against this server directly. |

**CI runs on SELF-HOSTED runners only — never GitHub-hosted.** Never add `*-latest` to a
workflow; GitHub bills only hosted runners. This repo has one registered runner
(`charless-MBP-maker-mac`, macOS/ARM64) as of 2026-08-24 — **verify rather than trusting that
date**, with an admin-scoped token (`gh api repos/:owner/:repo/actions/runners`; it 403s from
inside Actions).
