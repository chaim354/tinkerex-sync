# tinkerex-sync

The tinkerex sync server: one Rust binary, `tinkerex-sync`, built from `crates/tinkerex-sync`
([its README](crates/tinkerex-sync/README.md) has the full environment table, the storage
conventions and the gates). Production has run it since 2026-10-07; the Rails engine and host app
it replaced were deleted from this repository in Phase 6 (2026-10-14), and `git show 36bb82e:<path>`
reads them.

Clients split files into content-defined chunks (FastCDC), content-addressed and deduped. A commit
is an immutable version pointing at a chunk manifest; devices converge by pulling a per-user
changelog. **Chunk bytes move client-to-storage over presigned URLs and never through the server**
— it is a control plane and a URL signer, not a data path — with one sanctioned exception: the
`local` store's own signed blob endpoints, which are the storage when there is no bucket.

MIT licensed. Every dependency is permissive (MIT/Apache/BSD), checked by `cargo deny`.

## The binary

```sh
cargo build --release -p tinkerex-sync           # target/release/tinkerex-sync

tinkerex-sync serve [--bind 0.0.0.0] [--port 3000] [--migrate] [--scheduler]
tinkerex-sync migrate                            # create the schema, or adopt an existing one
tinkerex-sync device issue --email a@b.c [--name device]   # user_id:/device_id:/device_token:, once
tinkerex-sync device list  --email a@b.c
tinkerex-sync stats [--brief]                    # row counts; --brief prints "<n> nodes, <m> versions"
tinkerex-sync routes                             # every route it serves, one per line
tinkerex-sync doctor                             # configuration, schema presence, the Postgres pooler probe
tinkerex-sync gc retention    [--grace 3600]      [--user N] [--dry-run]
tinkerex-sync gc reap-pending [--ttl-hours 24]    [--user N] [--dry-run]
tinkerex-sync gc reap-storage [--grace-hours 24]  [--user N] [--dry-run]
```

`serve` answers the v1 API — 28 routes — plus `GET /up` (a readiness probe that reads the database)
and `GET /cable` (the realtime nudge, Action Cable framing). `device issue` prints its token once and
keeps only a SHA-256 digest: capture it into a file rather than reading it off the terminal; it is 43
base64url characters, not hex, and a pattern written for hex silently matches nothing. `--scheduler`
runs reap-pending hourly at :30, retention nightly at 03:15 UTC and reap-storage Sundays at 04:15
UTC; it is off by default, because the reapers delete bytes — read the `--dry-run`s first.

## Environment

| variable | meaning |
|---|---|
| `STORAGE_BACKEND` = `local` \| `s3` | required; `memory` is refused |
| `SECRET_KEY_BASE` | required; the HMAC key of the local blob URLs |
| `DATABASE_URL` (`postgres://…` or `sqlite:…`), else `SQLITE_DATABASE` | default `storage/production.sqlite3` |
| `CHUNK_LOCAL_DIR`, `CHUNK_PUBLIC_URL` | the `local` store (default `tmp/chunk-store`; URLs from the request's own host unless set) |
| `CHUNK_BUCKET`, `CHUNK_ENDPOINT`, `CHUNK_REGION` (default `auto`), `CHUNK_ACCESS_KEY_ID`, `CHUNK_SECRET_ACCESS_KEY` | the `s3` store |
| `SYNC_ADMIN_TOKEN` | the operator credential for `POST /v1/admin/libraries`; blank = that route answers 503 |
| `SYNC_VERIFY_FINALIZE` | default on: finalize checks that first-seen chunks really landed |
| `RETENTION_POLICY` = `keep_all` \| `tiered` | default `keep_all`, which prunes nothing |
| `SYNC_SCHEDULER=1` | the same as `serve --scheduler` |
| `SYNC_DB_POOLER_CHECK` = `warn` \| `refuse` \| `skip` | the Postgres statement-mode pooler probe at boot (default `warn`) |
| `RUST_LOG` (or `RAILS_LOG_LEVEL`), `SYNC_LOG_JSON=1` | logging |
| `BIND`, `PORT` | `serve`'s address, default `0.0.0.0:3000` |

The names are the ones the Rails host read, so the deployment's env block did not change at the
cutover.

## Storage: the two stores and the volume

- **`local`** — the server's own HMAC-signed blob endpoints (`PUT`/`GET
  /v1/chunks/blob/:user_id/:hash?exp=&sig=`), bytes under `CHUNK_LOCAL_DIR`, 64 MiB per chunk. What
  production runs: one box, no external object store.
- **`s3`** — R2, S3 or SeaweedFS through presigned SigV4 URLs, path-style, with a custom endpoint;
  the bytes never touch the server.

Either way a chunk's key is `chunks/<user_id>/<hash>`, per user. The database is SQLite or Postgres
— one SQL layer, the same schema the Rails host used (so a Rails-written database opens as is).

**The volume holds the library, not a cache.** In the image it is `/rails/host/storage` — the Rails
image's path, kept so the deployment's volume mounted over it unchanged — and with
`STORAGE_BACKEND=local` it holds both the SQLite file (`production.sqlite3`) and every chunk byte
(`chunk-store/`). It must be a real device, not a plain-local docker volume: a missing volume is not
an error to docker, which silently creates one and reports everything healthy.

## The image

`Dockerfile.rust`, published by `bin/build-and-push` (`linux/amd64`, tags `:<sha>-rust` and
`:latest`, or the revision tag alone with `SYNC_PUSH_LATEST=0`). **168 MB** on the deployment box,
where the Ruby image it replaced lists at 398 MB (measured 2026-10-07). It carries `curl` and
`sqlite3` because the maker repo's backup and restore scripts run them inside it.

- **`migrate` runs from the entrypoint, for `serve` only.** The first Ruby deploy came up on an
  empty volume with no schema: kamal reported success, the proxy reported healthy, and the first
  command to touch a table said `Could not find table 'users'`. Guarding on the command means
  `docker exec … tinkerex-sync stats` and one-off `gc` runs never migrate as a side effect.
- **`/up` reads the database, and has to.** A static 200 answers healthy for a server that cannot
  serve a single request, which is worse than no probe at all — it tells the proxy to send traffic.

## How the maker app and devices reach it

- **The maker app** (`chaim354/tinkerex`, `LIBRARY_BACKEND=chunk_remote`) runs this image as its
  `sync` Kamal **accessory** — a fixed container name, `tinkerex-sync`, on the kamal network — and
  reaches it at `CHUNK_REMOTE_URL=http://tinkerex-sync:3000`. Each maker user gets a library of
  their own, provisioned lazily through `POST /v1/admin/libraries` with `SYNC_ADMIN_TOKEN`. A
  deploy is `bin/build-and-push` here, then `bin/kamal accessory reboot sync` there (an accessory
  pulls; it never builds).
- **Devices** (`chaim354/tinkerex-client`) reach it through that deployment's kamal-proxy, which
  routes `sync.tinkerex.local` and `sync.tinkerex.home` to it, with a device token — the first from
  `tinkerex-sync device issue` or the admin route, siblings from `POST /v1/devices` on an enrolled
  device. They sync directly against it: the maker app is not in their path.

The wire is specified in `docs/sync-protocol.md` in the maker repo.

## The conformance corpus

`conformance/` holds sixteen scenario files of recorded HTTP exchanges — authored requests, real
responses — and `test/conformance_test.rb` replays them against a running server. The grader is
Ruby on purpose: one written by the same hands as the server would share its assumptions
([conformance/README.md](conformance/README.md) says why, and is the format's authority).

```sh
bundle install
bin/conformance       # builds, boots on a fresh database on 127.0.0.1:3004, runs the corpus
```

Measured 2026-10-14, the binary alone with the Ruby gone:

```
18 runs, 284 assertions, 0 failures, 0 errors, 0 skips
```

`bundle exec rake test` without a server runs the tooling's own tests and skips the sixteen scenario
tests — by design, and never mistaken for a pass: `bin/conformance` fails on any skip.

## Gates

```sh
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo deny check licenses sources
cargo test
bin/conformance
bundle exec rake test
```

CI runs all of them on a self-hosted runner (`.github/workflows/ci.yml`). The Postgres and S3 legs
are manual — the crate README has the commands.

## Security

Found a vulnerability? Report it privately through the repository's Security tab, as
[`SECURITY.md`](SECURITY.md) describes, rather than in a public issue.

## History

The sync engine was extracted from the [tinkerex](https://github.com/chaim354/tinkerex) monorepo
on 2026-08-20 with `git filter-repo`, preserving 108 commits, and lived here as a mountable Rails
engine plus a standalone host app until the Rust rewrite (`docs/superpowers/plans/2026-09-30-rust-rewrite.md`)
replaced it: the cutover on 2026-10-07 (`docs/superpowers/plans/2026-10-07-rust-cutover.md`), the
deletion of the Ruby in Phase 6. `docs/SYNC_SERVER.md` is the Rails implementation's notes, kept
for the reasoning.

**Commits from before the extraction show files at their historical paths** — `app/models/version.rb`
rather than `app/models/sync/version.rb`, `app/services/storage/` rather than
`app/services/sync/storage/`. Those moves changed the files enough that git does not record them as
renames, so any lineage tying old path to new would be an assertion nobody could verify; `git log
--all -- <old-path>` finds the earlier work. The monorepo retains the complete record, including
every commit that touched the maker application alongside the engine.
