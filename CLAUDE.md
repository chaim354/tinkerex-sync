# CLAUDE.md — tinkerex-sync

Project context for an AI coding agent (Claude Code) and human developers.

> **Provenance.** Rewritten 2026-10-14 for Phase 6 of `docs/superpowers/plans/2026-09-30-rust-rewrite.md`,
> when the Ruby engine and its host app left this repository and the Rust binary became the only
> implementation. §0–§3 and §6–§8 describe the binary. §4's rules were inherited from the maker app
> (`chaim354/tinkerex`) on 2026-08-25 and audited against the Ruby here that day; they are stated
> below in their Rust form (that plan's §5), each checked on the day of this rewrite against the
> code it names. The engine-era version of this file, and the Ruby it described, are
> `git show 36bb82e:CLAUDE.md` and `git show 36bb82e:app/…` — `main` before Phase 6.
>
> That audit does **not** cover the historical measurements quoted in §5 — "79 of 80 tests green"
> — which record past observations in the other repo, not current state.

---

## 0. Orientation — the things that surprise people

1. **This repository is one Rust binary plus a Ruby test corpus, and the Ruby is on purpose.** The
   server is `crates/tinkerex-sync` (its README has the subcommands, the env, the storage
   conventions and the gates). `conformance/` grades it over HTTP with a Ruby verifier and recorder,
   so the grader never shares the server's assumptions — the same failure shape as a fake that
   shares the real code's own bug (§5). If you are changing endpoint behaviour, the corpus moves
   with you. See §7.
2. **The v1 API is 29 routes; the maker app calls only 8 of them.** Do not infer the surface from
   what `chaim354/tinkerex` uses — versions, symlinks, search, locks, conflicts, share links and the
   blob PUT/GET all exist for *devices*, which are the primary client. Count them yourself:
   `tinkerex-sync routes` prints all 31 lines (the 29, plus `GET /up` and `GET /cable`), and
   `conformance/routes.txt` is that output checked in.
3. **Production has run this binary since 2026-10-07**, as the maker app's `sync` Kamal
   **accessory** — the cutover is `docs/superpowers/plans/2026-10-07-rust-cutover.md`, and its §0.5
   records the swap and the watch week. An accessory never builds: `bin/build-and-push` here
   publishes the image, `bin/kamal accessory reboot sync` in the maker repo rolls it (§6). The
   Ruby image it replaced is pinned as `ruby-4148fcd6…` in ghcr and on the box (the cutover plan's
   §6 is the rollback procedure), but nothing in this repository can rebuild it any more.
4. **The binary still writes the Rails schema and the Rails storage conventions** (rewrite plan D2:
   the same tables, datetime text, 0/1 booleans, `schema_migrations` rows, env names, image paths).
   That is what made the cutover reversible, and it is the on-disk format of every deployed volume.
   With the Ruby gone, changing it is possible — but only as a migration the binary grows
   (`schema::OWN_MIGRATIONS`, recorded in `tinkerex_sync_migrations`), never a casual rename
   (§4d). There is one so far, `20261022000001` (2026-10-22, tinkerex#473): two nullable columns on
   `devices`, `issuer_device_id` and `revoked_at`. Own migrations only ADD nullable columns, so the
   Ruby image could still boot on the file — but it would not read `revoked_at`, so a rollback to it
   would re-admit every revoked token. `serve` refuses to start while one is pending (`migrate`
   runs first in the entrypoint).

---

## 1. What this is

A local-first file sync server: one binary, `tinkerex-sync` — axum over tokio, sqlx over SQLite or
Postgres through one hand-written SQL layer. Files are split into **content-defined chunks
(FastCDC)** by the clients, content-addressed and deduped. A commit is an **immutable version**
pointing at a chunk manifest; devices converge by pulling a **per-user changelog**.

**Chunk bytes move client-to-storage over presigned URLs and never through this process** — the
server is a control plane and a URL signer, not a data path. The one sanctioned exception is the
`local` store's own HMAC-signed blob endpoints, which ARE the storage when a deployment has no
bucket (§4d). That is the single most important invariant here, and it is the one a "just stream it
through" change quietly breaks.

Licensing: **permissive only (MIT/Apache/BSD)**, enforced rather than remembered — `cargo deny check
licenses sources` against `deny.toml` is a CI gate (§8). Avoid GPL/AGPL in anything depended on or
shipped. SQLite is public domain; this server is MIT.

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
  **Keep versions** (don't prune) so restore always works; GC only sweeps refcount-0 chunks, and the
  default retention policy, `keep_all`, prunes nothing at all.

**Data model** (the Rails schema, unchanged — §0.4): `users(head_seq)`, `devices`, `nodes(node_id,
parent, name, kind, current_version, deleted)`, `versions(parent chain)`, `manifest_chunks`,
`chunks(refcount)`, `changelog_entries(seq)`, `pending_commits`, `conflicts`, `file_locks`,
`share_links`. Stable cross-device ids are string UUIDs.

**Three channels:** HTTPS API (control), `/cable` (the "pull" nudge, Action Cable framing,
`{head_seq}` once per mutating request), direct to storage (chunk bytes via presigned URLs). The
nudge first worked at the cutover: the Ruby host refused the desktop client's Origin-less
connection, so the daemon had only ever polled; through the binary it arrives in 6.6 / 5.2 / 8.0 ms
(rewrite plan §7.3).

- **Push:** per file `commit` (begin → upload missing chunks → finalize); dirs via `mkdir`. The
  server appends one changelog entry, bumps `head_seq`, broadcasts.
- **Pull:** changelog delta since cursor → apply into the local SQLite → dehydrate changed
  placeholders. The delta is **paged** and full-resyncs when the cursor is below the server's
  `oldest_seq` (pruned-gap detection).
- **Hydrate:** on read, fetch missing chunks via presigned GET → local cache.
- **Conflict detection** (replaced v1 last-writer-wins): each commit sends its `base_version_id`;
  if it is no longer current the server records a **conflict** (both versions kept) instead of
  silently dropping an edit. A base that IS current is a clean fast-forward, and so is a stale base
  from the device that wrote the current version (the same-device exception).

Normative wire spec: `docs/sync-protocol.md` in the maker-app repo (`chaim354/tinkerex`) — it
should probably move here; both sibling CLAUDE.md files currently point at it there, so moving it
means updating them in the same change. The recorded truth is the corpus (§7); where the two
disagree, the scenario wins.

**`docs/SYNC_SERVER.md` is HISTORICAL** — the Rails implementation's notes, kept for the reasoning.
Its pooler section's substance is the `doctor` subcommand now. The `next_seq` row lock (§4b)
genuinely requires session- or transaction-mode pooling on Postgres; `tinkerex-sync doctor` probes
for a statement-mode pooler (two statements must see one backend pid, and a session advisory lock
must still be held at the second), and `serve` runs the same probe at boot — **warning by default**.
`SYNC_DB_POOLER_CHECK=refuse` turns a failed probe into a boot refusal; `skip` (or
`DB_SKIP_POOLER_CHECK=1`) does not probe. Refusal stays opt-in deliberately: a probe that REFUSES to
boot takes a deployment down exactly when it is misconfigured, which is its job and not a switch to
flip in passing. Nothing to probe on SQLite.

---

## 3. Security

- **Tenant = user** (one library, that user's own devices). Isolation is `user_id` scoping in every
  query.
- **A client holds only a device token** — 32 random bytes, base64url without padding (43
  characters), stored as SHA-256 hex. No storage credentials: it gets short-lived, per-object
  **presigned URLs** for a per-user key `chunks/<user>/<hash>` — SigV4 on the `s3` store,
  `HMAC-SHA256(SECRET_KEY_BASE, "user\nhash\nexp")` on the `local` one — so cross-user chunk access
  is impossible and storage and dedup are per-user. `/v1/chunks/download` additionally only mints
  URLs for chunks the requester owns.
- **`POST /v1/admin/libraries` is gated by `SYNC_ADMIN_TOKEN`**, an operator credential a device
  token can never satisfy (constant-time compare; blank answers 503, never a boot refusal). This is
  what lets the maker app provision a per-user library lazily. Both sides must resolve the SAME
  1Password item or the far side answers 503.
- **Presigning is local** (HMAC, SigV4) — chunk URLs are verifiable without the storage being
  reachable.
- **Two kinds of credential, told apart by `devices.issuer_device_id`** (`models::Device`). A
  **library credential** (NULL) is minted outside the device API — `device issue`, or the admin
  door, which is how the maker app holds each user's bootstrap token — and so is every row older
  than migration `20261022000001`. A **device credential** was minted by `POST /v1/devices`, which
  records the minting device. The difference decides both rules below, and it is deliberate that
  the maker app's own token can be neither revoked over HTTP nor idled out: the admin door refuses
  an email it already has, so nothing could mint that library another one without an operator.
- **`DELETE /v1/devices/:id` revokes, and who may is the lineage** (`services::revocation`). A
  library credential may revoke any device credential of its library; a device credential only
  itself and what it minted; nobody revokes a library credential through it (403
  `library_credential`; a device outside the caller's reach is 403 `forbidden`). Another library's
  id, or an unknown one, is the plain 404. A revocation cascades to everything the target minted,
  keeps the rows (`revoked_at`, set once) and is idempotent. `SYNC_ADMIN_TOKEN` reaches no existing
  library's devices, on purpose; the operator's `tinkerex-sync device revoke --id` is the only
  door that revokes a library credential.
- **`DEVICE_IDLE_DAYS`** (default 90, `0` = off — the maker app's variable and parsing rule): a
  DEVICE credential unused that long stops authenticating; library credentials never idle out.
  `last_seen_at` moves at most once per `LAST_SEEN_RESOLUTION_SECONDS` (300), never on a refused
  request.
- **Every device-token door admits through `auth::admit_token`**, the HTTP routes and `/cable`
  alike; a refused token is the same `{"error":"unauthorized"}` 401 (or `/cable` `disconnect`
  frame) an unknown one gets. An open `/cable` socket is cut the moment the door revokes its device
  (a hub event) and re-admitted every `cable_recheck` (60 s), which is what reaches an operator's
  out-of-process revoke and idle expiry — and what keeps a connected device in use, so a device
  holding its socket open never idles out. Not reached by a revocation: a request already past
  authentication, presigned URLs already handed out (until their `exp`), a lock (its 300 s TTL).
- **Device-token verification is duplicated in the maker app, by structural necessity and with no
  guard.** Its own v1 API authenticates its own `devices` table and cannot call this server to do
  it. Change `crates/tinkerex-sync/src/auth.rs`'s `authenticate` and the maker's in the same breath
  (maker CLAUDE.md §14j). Both now revoke and idle-expire; the deliberate differences are this
  side's, and they are the two above — a library credential (the maker app's own token here)
  never idles out, and `last_seen_at` is throttled where the maker stamps every request.

---

## 4. Invariants (inherited from the maker app, in their Rust form)

Each line below cost a real bug **in the maker app's repo, while the engine lived there**
(sections `§14a`/`§14e`/`§14j` in the original). The Rust port made each one structural where it
could — an API that cannot be called in the wrong order — and kept a test that fails when the
structure is bypassed; every such guard has a mutation check on record in the commit history (the
guard was broken, the test went red, the guard was restored). Rust doc comments name the Ruby
class each module ported; the Ruby is `git show 36bb82e:app/…`.

### 4a. The in-process adapter — gone

The in-process `FileLayer::Chunk` adapter left with the engine; the maker app's
`FileLayer::ChunkRemote` is the only adapter now, and its rules are the maker's CLAUDE.md §14a.
Four of 4a's rules were about the server, not the adapter, and stand in §4d.

### 4b. Sequencing, refcounts and GC

- **The seq comes first, by construction.** `services::mutation::UserWrite::begin` opens the
  transaction (`BEGIN IMMEDIATE` on SQLite), takes the user row lock (`FOR UPDATE` on Postgres) and
  allocates the changelog `seq` BEFORE it hands the transaction to anyone, and it is the only way
  to get one — so no write path can insert an FK-bound row ahead of the lock, which is the
  `FOR KEY SHARE`→`FOR UPDATE` lock-upgrade deadlock concurrent commits once hit. A cascade
  (`DELETE /v1/nodes/:id`) takes one seq per node inside the same write and returns the last.
  `tests/concurrency.rs` proves gapless, duplicate-free allocation under contention (16×25 on
  SQLite; on Postgres too when `TEST_DATABASE_URL` is set). **A statement-mode pooler breaks it** —
  §2's `doctor` probe exists for that.
- **EVERY REFCOUNT WRITE GOES THROUGH `models::touch_refcounts`, which always moves `updated_at`.**
  `gc::sweep_orphans`' grace window filters on `updated_at`; a refcount write that left it behind
  made the filter test a chunk's CREATION age, not its ZEROING age, so for every real chunk the
  promised protection **did not exist**. No other code writes `chunks.refcount`.
  **Beware the test shape that hid it** — every sweep test hand-set `updated_at`, and the "within
  grace" one used a chunk created moments earlier, so it passed either way.
- **`gc::sweep_orphans` deletes compare-and-swap, row before bytes.** It takes no user lock, so its
  batch is a snapshot a concurrent finalize can re-reference **0 → 1 while uploading nothing**; the
  DELETE re-asserts `refcount <= 0`, a lost race keeps the bytes, and the row goes before the bytes
  so a storage failure orphans bytes at worst (a later sweep reclaims them), never a live version.
- **`gc::prune_version` is claim-then-decrement under the user lock**: the version row's delete is
  the claim, and only the pass that removed it decrements, so two overlapping retention passes
  cannot decrement twice for one removal. The `refcount > 0` guard on a decrement prevents a
  NEGATIVE refcount, which was never the bug.
- **`share_links` protect versions, and so do open conflicts.** `gc::referenced_version_ids` adds
  both sides of every unresolved conflict and every LIVE share link's version to the keep-set.
  **Drop the share-link line and nightly retention silently destroys the bytes behind URLs users
  have already sent to other people** — no build break, no red test on `keep_all`; `tests/gc.rs`
  pins it under the tiered policy for exactly that reason.
- **The two orphan reapers keep deliberately DIFFERENT pending-commit guards.** `gc reap-pending`
  reads only EXPIRED pending rows and must exclude the very rows it is destroying, or it reclaims
  nothing; `gc reap-storage` lists the keyspace and is the backstop, so EVERY pending row protects
  there, with no age filter. Narrow the storage reaper to match and it deletes a chunk a slow live
  commit is still uploading (`services/reapers.rs` has the full argument).
- **Failure mode throughout: silent permanent data loss**, managed/tiered only (`keep_all` never
  decrements). The scheduler (`serve --scheduler`, or `SYNC_SCHEDULER=1`) runs these for real, so
  it is turned on only after reading `gc … --dry-run` against the live database — the watch week's
  read 0 / 0 / 0 (cutover plan §0.5).

### 4c. Engine structure — gone

4c's rules were about a Rails engine mounted inside a host app — its table-name prefix, its route
drawer, its obligations on the host, the minimal host that proved it booted alone. They died with
the engine and have no Rust counterpart. Two of 4c's lessons were about writing guards in general,
and stand in §5.

### 4d. The wire and the process

- **Bytes stay out of the process except the `local` blob tier**, and the body limits are
  per-route: `POST /v1/commit` 16 MiB (a 100,000-entry manifest is ~10 MiB of JSON), every other
  JSON route 1 MiB, the blob PUT 64 MiB (413 above each), and a 120 s request timeout (408); the
  WebSocket is exempt. `tests/limits.rs` posts over each body limit.
- **Keys are user-scoped.** `store::key_for(user, hash)` → `chunks/<user>/<hash>` is the only key
  constructor, and a client-supplied hash must be 64 lowercase hex (`ids::is_chunk_hash`) before it
  becomes a key or a row — `commit` refuses it with 422, `chunks/download` omits it — so
  `"../7/deadbeef"` can never escape the per-user prefix on a path-based S3 gateway.
- **Rows round-trip Rails** (§0.4): datetime text `YYYY-MM-DD HH:MM:SS` with six fractional digits
  only when nonzero, booleans 0/1, NULLs bound with their column's type — measured in
  `src/db/README.md`. The rollback rehearsal proved it both ways on a copy of the production volume
  (rewrite plan §7.1).
- **Adapter-agnostic SQL**: one text for both drivers, no `pg_*`/`json_*`-style function in a hot
  path. `TEST_DATABASE_URL=postgres://…` runs the whole `cargo test` suite on Postgres.
- **The read services cost a constant number of statements**, asserted as constancy in N, never a
  literal (`tests/query_budget.rs`).
- **`/cable` checks no `Origin` and accepts both channel identifiers the clients have sent**
  (`src/http/cable.rs`). Do not "tighten" it: the deployed desktop client sends no `Origin` and the
  bare identifier, and the device token in the query string IS the authorization — there is no
  browser session to forge. Which is why it is admitted by the same rule as every route, and not
  only once: a socket outlives the request that opened it, so it is re-admitted on a timer and cut
  on a revocation (§3). A `/cable` that looked a token up without `auth::admit_token` — what it did
  until 2026-10-22 — would keep nudging a revoked device for as long as it stayed connected.
- **The device-facing trash restore keeps a caller-supplied `to_root`, deliberately.** Without it
  an orphan (its parent still tombstoned) is a 409 `parent_deleted`; with it, the orphan is
  re-parented to the library root. The maker app takes the strict 409 because a browser Restore
  click has no prompt to offer; a device client can ask for either and prompt its own UI. Do not
  "fix" the two into agreement — `05-trash.yml` pins both arms.
- **Restoring from the trash has no destination-vacant check**, so a revive can land two live nodes
  sharing one `(parent, name)` where the maker's share/s3 backends refuse that clobber. Pre-existing,
  recorded rather than closed.
- **Undeleting an ALREADY-LIVE node is an idempotent success** (`seq: null`, nothing appended) —
  structural, not arbitrary: anything else means raising about a file that IS restored.
- **`POST /v1/commit` validates the manifest exhaustively and the name only for presence**, so
  `"../../escape.txt"` and reserved names like `.trash` / `.maker-tmp-*` create live nodes here. The
  maker app closes this **at its own doors** (`Library::ReservedNames`,
  `Maker::MoveNode.valid_leaf_name?`), and a device push through a real mount gets no such check —
  macOS mounts push `.DS_Store` nodes through it by design.

---

## 5. Working agreements

- **Permissive licenses only** (§1); check new deps — `cargo deny` will.
- **Keep bytes out of the server process** — presigned URLs, control plane only (§4d's one
  exception is the `local` blob tier). This is the invariant most worth defending here.
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
  **Assert the WIRE format, not the round-trip.** The corpus's Ruby grader exists for this reason.
- **A GUARD THAT SKIPS ON THE THING IT ASSERTS IS VACUOUS.** A boot test that skipped when the
  module it asserted about was loaded meant the mutation which loaded it skipped every test and
  reported **success**. Skip on whether the leg was **invoked**, so absence is the claim rather than
  the precondition. Found by mutation-checking, not by reading.
- **A GUARD THAT SCANS A LIST DIES SILENTLY WHEN THE LIST EMPTIES.** Two architecture guards were
  `assert_empty offenders` over a directory glob; a repository move made the glob `[]`, which
  satisfies `assert_empty` perfectly, and the guard went on **passing over nothing**. Assert the
  scanned set is **non-empty** before trusting what it reports — the corpus verifier refuses an
  empty scenario directory and an empty `conformance/routes.txt` for exactly this reason (§7).
- **Prefer a probe over an argument.** A final whole-branch review once found five real bugs of
  which four were already recorded as unreachable, deferred, or verified — the contribution was
  *probing*, not thinking.
- **The suite being green is not evidence a guard works** if the guard's precondition is never
  established in test. Drive the real request.

---

## 6. The image and `bin/build-and-push`

`Dockerfile.rust` is the repository's only image: a `rust:1.99.0-bookworm` build stage (the same
toolchain `rust-toolchain.toml` pins — bump the two together) and a `debian:bookworm-slim` runtime
with `ca-certificates` (the `s3` store's HTTPS), `curl` and **`sqlite3`** — the last two because
the maker repo's `bin/restore-db` and `ops/backup-db.sh` run them INSIDE the deployment's own image;
without `sqlite3` the nightly `sync` backup fails from the first night (cutover plan §0.3.1, closed
by six green nights). **168 MB** on the Unraid box's daemon, where the Ruby image it replaced lists
at 398 MB (measured 2026-10-07).

- **The Ruby image's paths, port and uid, on purpose** (D2): `WORKDIR /rails/host`, the SQLite file
  and — with `STORAGE_BACKEND=local` — every chunk byte under `/rails/host/storage`, port 3000,
  uid 1000. The maker's accessory volume `tinkerex_sync_storage:/rails/host/storage` mounted over it
  unchanged at the cutover. **The volume holds the library, not a cache**: it must be a real device,
  not a plain-local docker volume, because a missing volume is not an error to docker — it silently
  creates one and everything looks healthy.
- **`migrate` runs in the entrypoint, for `serve` only** (`bin/docker-entrypoint-rust`), so
  `docker exec … tinkerex-sync stats` and one-off `gc` runs never migrate as a side effect. It
  creates a fresh schema or adopts an existing one untouched, and refuses a half-migrated file.
- **`/up` reads the database** (`SELECT count(*) FROM users`; 503 otherwise). A static 200 answers
  healthy for a server that cannot serve a single request — worse than no probe.

**`bin/build-and-push` exists because an ACCESSORY NEVER BUILDS.** `kamal accessory boot/reboot`
only *pulls* a named image, so this script is the deploy's first half: it builds `linux/amd64`
from `Dockerfile.rust` and pushes `:<sha>-rust` and `:latest`, or only the revision tag with
`SYNC_PUSH_LATEST=0` (promotion is then a separate `imagetools create` retag; the script prints
it). The revision rides in the image as the `org.opencontainers.image.revision` label — the only
reliable answer to "what is deployed", since `kamal accessory details` prints `:latest`. The `-rust`
suffix outlived the Ruby so the cutover's tags keep their meaning. `SYNC_IMPL` selects nothing any
more: `rust` is accepted, anything else is refused before the registry login, because
`SYNC_IMPL=ruby` was the rollback image's rebuild command and ignoring it would push a Rust build to
`:latest` under that impression. `test/build_and_push_test.rb` drives the real script.

- **After any `:latest` move, verify ON THE BOX before trusting a reboot.** On 2026-10-07 a retag
  read back from the Mac for a minute and then reverted at the registry, and the reboot inside that
  window redeployed the old image while reporting success; only the running container's labels
  caught it (cutover plan §0.5). `docker pull` on the box must say `Downloaded newer image`, then
  read the labels.
- **Keep git worktrees OUTSIDE this checkout** before running it: the revision is `-dirty` whenever
  `git status --porcelain` is non-empty (untracked files count, because `crates/` is copied from the
  working tree), and a worktree placed under the checkout did exactly that once.
- **There is no standalone deploy of this repository.** Its own `config/deploy.yml` (a kamal
  *service* for the Ruby host) collided with the accessory on the `service=tinkerex-sync` label —
  one shape per box — and left with the Ruby in Phase 6.

---

## 7. The conformance corpus

`conformance/` is how the Rust rewrite was graded, and how the binary is graded now — against
**recorded HTTP exchanges**, never ported unit tests, which would bind grader and server by shared
code rather than by the wire. The grader stays Ruby (rewrite plan D5): a verifier written by the
same hands as the server would share its misunderstandings. `conformance/README.md` is written for
*an implementer who does not read Ruby* and is the authority on the format; this section only says
what a change in *this* repo owes it.

- **Seventeen scenarios** (`conformance/scenarios/01-enrolment.yml` … `17-device-revocation.yml`), a
  `runner.rb` (the matcher the verifier and the recorder share), a `schema.json`, and `routes.txt`.
- **THEY SKIP UNLESS `SYNC_SERVER_URL` IS SET**, because they drive a **real running server** over
  HTTP. `bundle exec rake test` on its own reports **17 skips — the entire corpus** (beside the
  matcher's and the build script's own tests). A green local run therefore proves nothing about the
  wire.
- **`bin/conformance` closes that hole, and CI runs it.** It builds the binary, boots it on a FRESH
  database (`11-admin.yml`, `14-tenancy.yml` and `17-device-revocation.yml` provision fixed emails) with a freshly issued device
  and the corpus's fixed `SYNC_ADMIN_TOKEN`, runs the verifier, and **parses the run's own summary
  line**, failing on a nonzero skip count *or on zero runs at all* — the emptier failure, which
  otherwise reports a clean "0 runs, 0 skips" that looks exactly like success. Minitest cannot let
  one test assert about another's skip, so the guarantee has to live outside the suite.
- **Every route the binary serves must be exercised by a scenario, or named as an exception with a
  reason.** `conformance/routes.txt` is `tinkerex-sync routes` checked in; `tests/routes.rs` holds
  it to the binary byte for byte, and the verifier's coverage check demands a scenario step for
  every line except `COVERAGE_EXCEPTIONS` (`GET /up`, `GET /cable`), refusing an empty list first.
  It replaced the check that drew the Ruby engine's routes. Adding a route: regenerate the file
  (`cargo run -q -p tinkerex-sync -- routes > conformance/routes.txt`), then record a scenario.
- **A change to endpoint behaviour must move the corpus with it** (`bin/conformance-record`,
  against the binary — it is the recording reference since the cutover, D6), and the README's own
  review step is not optional: it is what makes a *recorded* corpus trustworthy rather than merely
  self-consistent. Issue recording devices under the default name; `08-locks.yml` expects it.

---

## 8. Build, run and CI

```sh
# The gates (CI runs every one of them; see below):
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo deny check licenses sources        # permissive licences only (deny.toml)
cargo test                               # 123 tests, every TestServer on a temp SQLite file
bin/conformance                          # 19 runs, 314 assertions, 0 failures, 0 errors, 0 skips
bundle install && bundle exec rake test  # 41 runs, 76 assertions, 17 skips -- the corpus (§7)

# The legs CI does not run (no Postgres, no bucket on the runner); each prints NOT RUN when its
# variable is unset rather than passing silently, and each needs an EMPTY database or bucket:
TEST_DATABASE_URL=postgres://…/fresh_db cargo test
CONFORMANCE_DATABASE_URL=postgres://…/fresh_db bin/conformance
TEST_S3_ENDPOINT=http://127.0.0.1:8333 TEST_S3_BUCKET=b \
  TEST_S3_ACCESS_KEY_ID=… TEST_S3_SECRET_ACCESS_KEY=… cargo test --test s3_roundtrip

# Run it:
STORAGE_BACKEND=local SECRET_KEY_BASE=dev cargo run -p tinkerex-sync -- serve --migrate --port 3002
cargo run -q -p tinkerex-sync -- device issue --email you@example.com   # a device token, once

# The image, built locally and smoke-tested WITHOUT pushing (crates/tinkerex-sync/README.md has
# the whole smoke), then published:
docker buildx build --platform linux/amd64 -f Dockerfile.rust -t tinkerex-sync:rust-local --load .
SYNC_PUSH_LATEST=0 bin/build-and-push    # :<sha>-rust only; prints the promote command
bin/build-and-push                       # :<sha>-rust and :latest -- arms the next accessory reboot
```

The Postgres legs were green on 2026-09-30 (Postgres 16.13: the whole `cargo test` suite, and the
corpus at `18 runs, 284 assertions`) and again on 2026-10-22 (Postgres 16.14 in a local
`postgres:16` container: all 123 tests, and the corpus at `19 runs, 314 assertions`); they stay
manual gates until a runner has Postgres.

**`rust-toolchain.toml` pins 1.99.0 with the `minimal` profile plus `rustfmt` and `clippy`**, for
every cargo call inside this checkout — CI's included — so clippy grades the same lints everywhere
(#16's one red CI run was a clippy version gap). Minimal, because the maker repo's
`bin/ci test-chunk-remote` builds this crate on its own runners and pays the toolchain install once
per runner.

**Two env knobs that belong to THIS repo and do nothing on the maker app:**

```sh
# Real S3/SeaweedFS chunk storage (presigned PUT/GET)
STORAGE_BACKEND=s3 CHUNK_ENDPOINT=http://192.168.1.8:8333 CHUNK_BUCKET=my-bucket \
  CHUNK_REGION=us-east-1 CHUNK_ACCESS_KEY_ID=admin CHUNK_SECRET_ACCESS_KEY=secret
```

`SYNC_VERIFY_FINALIZE=0` — finalize's verify-the-bytes-landed check defaults **ON**, but the
desktop client's integration suites move chunk bytes through `SharedDirIO`, not this server's
store, so the server cannot see them and finalize would refuse a commit that is actually fine.

**CI: self-hosted runners only, never `*-latest`** — GitHub bills only hosted runners.
`.github/workflows/ci.yml` has two jobs on `[self-hosted, macos]`: `rust-check` (fmt, clippy,
cargo-deny, `cargo test`) and `conformance` (the Ruby tooling's own tests with no server, then
`bin/conformance`). This repo has one registered runner (`charless-MBP-maker-mac`, macOS/ARM64,
since 2026-08-24) — **verify rather than trusting that**, with an admin-scoped token
(`gh api repos/:owner/:repo/actions/runners`; it 403s from inside Actions). A job matching no
online runner does not fail: it queues for 24 h and is cancelled, which reads as UNSTABLE, not red.

---

## 9. Related repos

| repo | role |
|---|---|
| `chaim354/tinkerex` | The **maker app** — projects, inventory, model library, addons. A CLIENT of this server via its `FileLayer::ChunkRemote` adapter (`LIBRARY_BACKEND=chunk_remote`), and the deployment that runs this image as its `sync` accessory; its `bin/sync-server` builds and boots this binary for its `bin/ci test-chunk-remote` gate. Owns `docs/sync-protocol.md`. |
| `chaim354/tinkerex-client` | The **Rust crates + Tauri desktop app** — `fs-provider`, the per-OS mounts, `sync-client`, `sync-engine`. Syncs against this server directly. |
