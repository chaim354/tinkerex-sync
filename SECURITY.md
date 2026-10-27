# Security

`tinkerex-sync` is the source of truth for every Tinkerex library that syncs: the tree, the
versions, the changelog, the device-token digests and, on the `local` store, every chunk byte. A
vulnerability in it is a vulnerability in someone's home server and in every device syncing against
it. Please report one privately, not in a public issue or pull request.

## Reporting a vulnerability

Open a private report on GitHub: this repository's **Security** tab, then **Report a
vulnerability**. It reaches the maintainer and nobody else. The other Tinkerex repositories have the
same door — `chaim354/tinkerex` (the maker app), `chaim354/tinkerex-client` and
`chaim354/tinkerex-addons` — so report against the one that holds the code. A flaw in how the maker
app *calls* this server (its `FileLayer::ChunkRemote` adapter, or the sign-in that hands a device
its sync grant) belongs in `chaim354/tinkerex`, which is also the place when unsure.

Include what you can: the commit or image tag, `STORAGE_BACKEND` (`local` or `s3`), the database
(SQLite or Postgres), the requests that reproduce it, and what an attacker gains — another user's
nodes, versions or chunks, a working token, or a byte written outside `chunks/<user_id>/`. A proof
of concept against your own server is welcome: the crate README
([`crates/tinkerex-sync/README.md`](crates/tinkerex-sync/README.md)) shows how to run one, and a scenario in
the `conformance/` format is the most useful reproduction there is, though not required. Please do
not test against `tinkerex.com`, the shared public demo, or any deployment you do not run.

Expect an acknowledgement within a week. This is a one-person project with no bug bounty: a fix
lands as an ordinary pull request, the report is credited in it unless you ask otherwise, and the
advisory is published once the fix is out.

## Scope

In scope: the `tinkerex-sync` binary built from `crates/tinkerex-sync` — the v1 API
(`tinkerex-sync routes` prints every route), `/up`, `/cable`, the `local` store's signed blob
endpoints, and the `migrate`, `device`, `doctor` and `gc` subcommands — and the image built from
`Dockerfile.rust`, `ghcr.io/chaim354/tinkerex-sync`. That image is not publicly pullable, so build
it yourself; the crate README has the build and the smoke test. The Ruby in `conformance/` and
`test/` grades the server over HTTP and never runs in a deployment, so a flaw there is an ordinary
issue.

One thing is documented behaviour rather than a flaw, and belongs in an ordinary issue if you think
it should change: **deleting a file keeps it.** A delete is a tombstone, the default
`RETENTION_POLICY=keep_all` prunes no version, and bytes leave storage only through the `gc`
reapers — which is what makes a restore always work.

## Supported versions

Only the current `main` branch and the image it publishes (`:latest`, and that commit's
`:<sha>-rust` tag) are supported. There are no releases or release branches. The Ruby image still
in the registry (`ruby-4148fcd6…`) is a historical artefact, not a supported version.
