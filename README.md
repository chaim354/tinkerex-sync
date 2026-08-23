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
| `User`, `Node`, `Device` | `TinkerexSync::HOST_MODELS`. `User` must expose `next_seq!`, `Device` must expose `.authenticate`, `Node` must expose `#file?`. |
| `ApplicationRecord`, `ApplicationJob`, `ApplicationCable::Channel` | Every engine class names these explicitly, so `isolate_namespace` cannot misresolve them. |
| `limits_concurrency` on `ApplicationJob` | Used by `Sync::RetentionJob`. This is **solid_queue's extension, not core ActiveJob** — the gemspec does not depend on solid_queue, because the host picks its own queue adapter. |
| Routes | `Sync.draw_v1_routes(mapper)`, called inside your own `namespace :v1`. |
| **Action Cable adapter** | `config/cable.yml`. The engine broadcasts on every commit, mutation and restore — that is how devices learn there is something to pull. With no adapter configured, ActionCable's config is `nil` and the broadcast raises `undefined method 'fetch' for nil` **from inside the commit**, naming neither cable nor configuration. The engine cannot default it: `async` is wrong for more than one process, `redis` needs a server, `solid_cable` needs a database. |
| **Device enrolment** | The engine draws **no** devices route — obtaining a token is entirely yours, which is why `Device` is in `HOST_MODELS`. `host/` ships one answer (an operator-minted first token, siblings enrolled by an authenticated device, no password anywhere). |

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

204 runs, 664 assertions, 0 failures. (One skip: a Postgres pooler probe, which needs a live
Postgres.)

`test/dummy` is a minimal host that supplies exactly the obligations above and nothing else — its
job is to prove the engine loads and runs in a process that has never seen the application it was
extracted from.

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
