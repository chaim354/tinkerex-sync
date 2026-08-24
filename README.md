# tinkerex-sync

A local-first file sync engine, as a mountable Rails engine.

Files are split into content-defined chunks (FastCDC), content-addressed and deduped. A commit is
an immutable version pointing at a chunk manifest; devices converge by pulling a per-user
changelog. **Chunk bytes move client-to-storage over presigned URLs and never through Rails** —
the engine is a control plane and a URL signer, not a data path.

MIT licensed.

## What the host must supply

The engine deliberately does not define a tenant, a catalog or a credential — a host that already
has those should not be made to adopt a second set.

| Obligation | What it is |
|---|---|
| `User`, `Node`, `Device` | `TinkerexSync::HOST_MODELS`. `User` must expose `next_seq!` and, since Arc C's admin provisioning endpoint, `.create!(email:)`/`.exists?(email:)` against a `users.email` column carrying presence + a DB-level unique index. `Device` must expose `.authenticate` and, since the same arc, `.register!(user:, name:)` returning an instance whose `#plaintext_token` answers the one-time-shown token. `Node` must expose `#file?`. Both hosts this gem has ever had (`host/`, `test/dummy`) already carried the email column and `Device.register!` before Arc C existed — this row documents what was already true in practice, not a new constraint on a working host. |
| `ApplicationRecord`, `ApplicationJob`, `ApplicationCable::Channel` | Every engine class names these explicitly, so `isolate_namespace` cannot misresolve them. |
| `limits_concurrency` on `ApplicationJob` | Used by `Sync::RetentionJob`. This is **solid_queue's extension, not core ActiveJob** — the gemspec does not depend on solid_queue, because the host picks its own queue adapter. |
| Routes | `Sync.draw_v1_routes(mapper)`, called inside your own `namespace :v1`. |
| **Action Cable adapter** | `config/cable.yml`. The engine broadcasts on every commit, mutation and restore — that is how devices learn there is something to pull. With no adapter configured, ActionCable's config is `nil` and the broadcast raises `undefined method 'fetch' for nil` **from inside the commit**, naming neither cable nor configuration. The engine cannot default it: `async` is wrong for more than one process, `redis` needs a server, `solid_cable` needs a database. |
| **Device enrolment** | The engine draws **no** route for enrolling a sibling device onto an *existing* user — obtaining that kind of token is entirely yours, which is why `Device` is in `HOST_MODELS`. `host/` ships one answer (an operator-minted first token, siblings enrolled by an authenticated device, no password anywhere). The engine **does** draw one provisioning route, `POST /v1/admin/libraries` (`Sync::V1::Admin::LibrariesController`), gated by a distinct `SYNC_ADMIN_TOKEN` operator credential rather than a device token — it creates a *brand-new* User plus its first Device, not a sibling on one that already exists, which is a different enough operation that it lives in the engine rather than needing every host to reimplement it. |

### What the engine defaults for you

`config.x.verify_finalize` — read by `Sync::V1::CommitsController#finalize`. Until 2026-08-21 only
the tinkerex monorepo set it, so every other host got an **empty `OrderedOptions`** (not `nil` —
`config.x.anything` auto-vivifies, and an empty one is *truthy*) and finalize crashed further in. The
engine now defaults it in its own railtie; a host initializer still wins.

## `host/` — a standalone sync server

A small, real Rails app: the engine, the three models, device enrolment, and nothing else. It is
what `chunk_remote` in the tinkerex maker app talks to.

```sh
cd host
bin/rails db:prepare
EMAIL=you@example.com bin/rails sync:device:issue   # prints a device token, once
STORAGE_BACKEND=local bin/rails server -p 3002
```

Then point a maker app at it:

```sh
LIBRARY_BACKEND=chunk_remote \
CHUNK_REMOTE_URL=http://127.0.0.1:3002 \
CHUNK_REMOTE_TOKEN=<the token above> \
  bin/rails server
```

**Verified end to end on 2026-08-22**, two processes with separate databases: upload (bytes
straight to storage, proxied by neither app), finalize, changelog pull, local-SQL `stat`, byte read,
`download`, `mkdir` and `move` with the `node_id` preserved — with `Sync` **undefined** in the maker
app's process throughout.

`test/dummy` remains, and is not redundant: it proves the engine boots with **only** the declared
obligations supplied, which a real host cannot prove because it supplies more. Two apps, two
questions, and they run in separate processes because two Rails applications cannot boot in one.

`Device` staying host-side is deliberate: its token is the only credential the v1 API accepts, so
an engine that owned it would leave a host's own API unable to authenticate.

### Routes are drawn, not mounted

There is no `mount Sync::Engine`. The engine's paths interleave with a host's own inside one `v1`
namespace, and a mount owns a whole prefix — introducing a `/v1/sync/` prefix to make one possible
would break every deployed client. So the host calls the drawer:

```ruby
namespace :v1 do
  # ...your own routes...
  Sync.draw_v1_routes(self)
end
```

The drawer lives in `lib/`, not `config/routes.rb`, because `Rails::Engine` evaluates that path
itself whether or not the engine is mounted — putting it there loads it twice.

### Capabilities

`Sync.capability_available?` / `Sync.capability_unavailable_message` default to **available,
always** — the correct answer for a bare mount, since this engine *is* the sync engine. A host that
can be configured with a non-versioned backend overrides them to gate the relevant endpoints (501).

## Schema

`db/engine_schema.rb` is one consolidated migration creating the eight tables the engine owns:
`changelog_entries`, `chunks`, `conflicts`, `file_locks`, `manifest_chunks`, `pending_commits`,
`share_links`, `versions`. Its eight `add_foreign_key` lines all name the host's `users` table.

## Tests

```sh
bundle install
bundle exec rake test
```

254 runs, 755 assertions, 0 failures. (12 skips with no live server configured — 11 conformance
scenario files plus a Postgres pooler probe, which needs a live Postgres; see
`conformance/README.md` for running the corpus for real. This line previously read "one skip,"
true before the conformance suite existed but stale for a while after — a claim naming a count is
only as good as whoever remembers to re-measure it after the next thing that changes it, which is
exactly the discipline `docs/STATUS.md`-style "verify a commit reference the way you verify a
guard" — one repo over — argues for.)

`test/dummy` is a minimal host that supplies exactly the obligations above and nothing else — its
job is to prove the engine loads and runs in a process that has never seen the application it was
extracted from.

## Deploying it

`Dockerfile` and `config/deploy.yml` are here. The image is **422 MB** against the maker app's
1.59 GB, because this one installs none of what that one needs — libvips, pdfium, resvg, f3d, the
Rust STL thumbnailer, Node and asset precompilation. This app is `api_only`; it holds chunks and
serves JSON.

```sh
kamal setup                                   # first time
kamal deploy
kamal app exec --reuse "env EMAIL=you@example.com NAME=laptop bin/rails sync:device:issue"
```

That last one prints a device token **once** and keeps only its digest. Capture it into a file
rather than reading it off the terminal; it is 43 base64url characters, not hex, and a pattern
written for hex silently matches nothing.

Three things worth reading before the first deploy:

- **`db:prepare` runs from the entrypoint, not from `CMD`.** Without it the container comes up on
  an empty volume with no schema. That is how the first real deploy shipped: kamal reported
  success, the proxy reported healthy, and the first command to touch a table said
  `Could not find table 'users'`. The entrypoint guards on the command really being the server, so
  `kamal app exec` and one-off rake tasks do not migrate as a side effect of running.
- **`/up` reads the database, and it has to.** A static 200 answers healthy for an app that cannot
  serve a single request, which is worse than having no probe at all — it actively tells the proxy
  to send traffic. Keep it a real query.

- **The volume holds the library, not a cache.** With `STORAGE_BACKEND=local` it is both the SQLite
  database and every chunk byte. It must be a real device, not a plain-local docker volume — a
  missing volume is not an error to docker, it silently *creates* one on the VM's own disk and
  everything looks healthy.
- **`CABLE_ADAPTER: async` is in-process only.** One web container is fine; with two, devices
  attached to one never hear the other's broadcasts and nothing reports it.

**Deployed 2026-08-23** to `192.168.1.95` (Unraid VM), reachable as `sync.tinkerex.local` and
`sync.tinkerex.home`. Verified against the running host, not against the suite: all eight engine
tables plus the three host tables present; `/up` 200 on both hostnames; `/v1/tree` 401
unauthenticated and 200 with a minted device token; and a full mutation round trip —
`POST /v1/nodes` -> `GET /v1/tree` -> `GET /v1/changes` -> `POST /v1/nodes/:id/move` ->
`DELETE` -> `GET /v1/trash` -> `POST /v1/trash/:id/restore`, with `head_seq` advancing 1 -> 5 and
each op appearing in the changelog. Probe data purged afterwards; the host is empty apart from one
issued device.

**The maker app is not pointed at it yet.** Nothing sets `LIBRARY_BACKEND=chunk_remote` against
this host; the three Unraid backends still run their own way. That cutover is a separate change.

## History

This engine was extracted from the [tinkerex](https://github.com/chaim354/tinkerex) monorepo on
2026-08-20 with `git filter-repo`, preserving 108 commits.

**Commits from before the extraction show files at their historical paths** — `app/models/version.rb`
rather than `app/models/sync/version.rb`, `app/services/storage/` rather than
`app/services/sync/storage/`, and the v1 controllers under `app/controllers/v1/` rather than
`app/controllers/sync/v1/`. That is what actually happened, and it is left that way on purpose:
those moves changed the files enough that git itself does not record them as renames, so any
lineage tying old path to new would be an assertion nobody could verify rather than something the
history shows. `git log --all -- <old-path>` finds the earlier work.

The monorepo retains the complete record, including every commit that touched the maker
application alongside the engine.
