# The Rust Cutover — Plan for the Agent That Runs It

Written 2026-10-07, the day the rewrite merged, for the agent (and operator) who will replace the
Ruby sync host in production with the Rust binary. It executes §7 of
`2026-09-30-rust-rewrite.md` and prepares §9. It was written from the three repositories' code and
scripts as merged that day, not from memory; every command below names the file it comes from, and
three things the rewrite plan got wrong were found while writing it (§0.3). Read §0 before anything
else: it says what is true today, and what the operator has to decide before the agent starts.

The whole design rests on one property the rewrite plan called **D2**: the Rust binary opens the
Ruby host's SQLite file and chunk volume in place, writes rows the Ruby image reads back unchanged,
and reads the same env names from the same image paths. So the cutover is a retag of one image
and a reboot of one container, and the rollback is the reverse retag. Nothing here migrates data,
and nothing here changes the maker app's `sync` accessory block except (optionally, §2.2) giving
it a door for devices.

---

## 0. Where things stand (2026-10-07)

### 0.1 What merged

| repo | PR | `main` | CI on `main` |
|---|---|---|---|
| `chaim354/tinkerex-sync` | #16 (the server, the corpus at sixteen files, the image, the CI jobs) | `50d2803` | green (`test`, `conformance`, `conformance-rust`, `rust-check`) |
| `chaim354/tinkerex` | #376 (`SYNC_IMPL=rust bin/sync-server`, `bin/restore-db` through `tinkerex-sync stats`) | `5c496fa` | green (all seven jobs on the PR's merge ref) |
| `chaim354/tinkerex-client` | #10 (the suites enrol through the admin door) | `7ce72a0` | green (`mac-tests`) |

The rewrite plan's phases 0–3, §6 and §8 are checked off with measurements. **§7 (this plan) and
§9 (decommission) are not started.** The corpus grades both servers at
`18 runs, 284 assertions, 0 failures, 0 errors, 0 skips`.

### 0.2 What production runs today (read from `../tinkerex/config/deploy.yml`, the `sync:` block)

- The **Ruby host image** `ghcr.io/chaim354/tinkerex-sync:latest`, as the maker app's Kamal
  **accessory** `sync` on `192.168.1.95`. The container is named `tinkerex-sync` (fixed, which is
  what makes `CHUNK_REMOTE_URL=http://tinkerex-sync:3000` resolve). It is **internal-only**: the
  block declares no `port:` and no `proxy:`, so only another container on the kamal network can
  reach it. Today that is exactly one client, the maker app's base destination
  (`LIBRARY_BACKEND=chunk_remote`), including its `FileLayer::RemoteChangelogPullJob` every two
  minutes.
- The volume `tinkerex_sync_storage` mounted at `/rails/host/storage` holds **both** the SQLite
  catalog (`production.sqlite3`) and every chunk byte (`chunk-store/`, via
  `CHUNK_LOCAL_DIR=/rails/host/storage/chunk-store`). Losing it loses the library.
- Env: `STORAGE_BACKEND=local`, `CHUNK_LOCAL_DIR` as above, `CABLE_ADAPTER=async`,
  `RAILS_LOG_TO_STDOUT=1`; secrets `SECRET_KEY_BASE` (`.kamal/secrets-common`, item
  `op://tinkerex/tinkerex-sync/secret key base`) and `SYNC_ADMIN_TOKEN` (`.kamal/secrets`, item
  `op://tinkerex/tinkerex-sync-admin-token/password`). The Rust binary reads the same names; it
  ignores `CABLE_ADAPTER` and `RAILS_LOG_TO_STDOUT`.
- The nightly backup (03:30 America/New_York, `ops/backup-db.sh --to-volume tinkerex_backups
  --keep 14 chunk share s3 sync`) snapshots the catalog with `sqlite3 .backup` and tars the volume;
  `bin/backup-db sync` pulls an ad-hoc archive to the Mac; `bin/restore-db sync <archive> --into
  rehearsal --yes` restores into a throwaway volume `tinkerex_sync_storage-rehearsal`.
- The Rust image has **never been built**: `Dockerfile.rust` and `SYNC_IMPL=rust
  bin/build-and-push` exist, unexercised (no Docker on the box that built the rewrite).
- The revision of the Ruby image now running is **unknown from here**; §2.3 reads it off the box.

### 0.3 Three findings that change the rewrite plan's §7 (found while writing this)

1. **The Rust image has no `sqlite3` binary, and the backup and restore scripts run `sqlite3`
   inside the deployment's own image.** `ops/backup-db.sh` runs its worker as
   `docker run --rm --user 0 -v "$src:/src" "$image" sh -c "$WORKER"` where `$image` is the
   running `tinkerex-sync` container's image and the worker calls `sqlite3 .backup` and
   `PRAGMA integrity_check`; `bin/restore-db`'s `--into` verify does the same, and a real restore
   runs `bin/backup-db` first. `Dockerfile.rust` installs only `ca-certificates curl`; the Ruby `Dockerfile` installs
   `curl libjemalloc2 sqlite3`. **Cut over without fixing this and the nightly `sync` backup fails
   every night from the first one, and `bin/restore-db sync` cannot restore.** The rewrite plan's
   §8.3 said "`ops/backup-db.sh` needs nothing (it reads the volume with its own sqlite3)"; that
   sentence was wrong and is corrected there. Fix: §2.1.
2. **No desktop device can reach the deployed sync server today.** The accessory is internal-only
   (above). The §7.3 probes "a desktop client push/pull" and "the cable nudge observed in the
   daemon's log" therefore need a door first. The client repo's CI and scripts still point devices
   at `http://192.168.1.95`, which is the maker app behind kamal-proxy and has not served `/v1/*`
   since 2026-08-25. Decision D1 in §1.
3. **`bin/build-and-push` tags every build `:latest` and `:<git sha>` regardless of
   `SYNC_IMPL`.** A Ruby build and a Rust build from the same commit overwrite each other's
   revision tag, and any build moves `:latest`, which is what the accessory pulls on its next
   reboot. So the Rust image cannot be pushed for a rehearsal without also arming the next reboot
   to cut over. Fix: §2.1 (push the revision tag only; promote to `:latest` as its own step).

### 0.4 Rules that bind throughout

- **Never push to `main`; every change is a PR; merging needs the operator's explicit go-ahead.**
- **`bin/secrets-preflight` before every kamal command** (maker CLAUDE.md §14g; kamal cannot
  notice an unreadable secret and deploys an empty one).
- **Never print a secret**: not `SECRET_KEY_BASE`, not `SYNC_ADMIN_TOKEN`, not a device token.
  Device tokens are printed once by `device issue`; keep them in the shell session only.
- **Never `kamal deploy` from this repo's own `config/deploy.yml`** (it is a standalone *service*
  that collides with the accessory on the `service=tinkerex-sync` label; CLAUDE.md §8).
- **Never `bin/kamal accessory remove sync`** (it removes the container, the image and the
  accessory's data directory). Reboot is `bin/kamal accessory reboot sync`, nothing else.
- **Measure, then write it down.** Each phase ends with outputs pasted into a PR body and the
  matching checkbox in `2026-09-30-rust-rewrite.md` §7 ticked with the figures, exactly as §8 was.
  `bin/log` in the maker repo records the arc (`bin/log arc --from-pr N`) and the deploy
  (`bin/log deploy --image <tag> --dest sync`).
- **Who runs where.** Commands marked **[Mac]** need the operator's machine (kamal, `bin/secret`
  through 1Password, Docker Desktop with buildx, ssh to the box); **[box]** run over
  `ssh kamal1@192.168.1.95`; **[checkout]** run in a sibling checkout of the three repos. An
  agent without box access does the PR work and hands the operator the exact commands.

### 0.5 Progress — what has run (append here; the rewrite plan's §7 holds the checkboxes)

**2026-10-07, from the operator's Mac** (Docker Desktop with an amd64 buildx builder, cargo 1.99.0,
ssh to the box, 1Password service account), the day this plan merged:

- **Blocker, found first: the ghcr token is dead.** `op://tinkerex/ghcr.io/password` — a classic
  `ghp_` PAT, item last updated 2026-06-16 — gets **401** from `api.github.com/user` and `denied`
  from `ghcr.io/v2/`; the box's stored docker credential is the same token and `docker manifest
  inspect` fails there too. `bin/secrets-preflight` reports it `ok` because it checks that a secret
  RESOLVES, not that it works. Every registry step waits on a new PAT (`write:packages`,
  `read:packages`) in that item: §2.3's ghcr pin, §2.4's push, and **every `kamal accessory
  reboot`** — `reboot` is `prepare` (registry login) → pull → stop → remove → boot, so it fails
  before anything is stopped: safe, but failed. The last recorded deploys were ~2026-09-08; a
  90-day PAT minted 2026-06-16 expired ~2026-09-14.
- **§2.1 prep PR: this branch** (`claude/cutover-prep`). Gates on the Mac: fmt, clippy, deny green;
  `cargo test` green; `bin/conformance-rust` `18 runs, 284 assertions, 0 failures, 0 errors, 0
  skips`; rustc 1.99.0. Image built `linux/amd64` without pushing: **168 MB** loaded on the box
  (the Ruby image there: 398 MB; Docker Desktop lists the Rust image at 44 MB, compressed),
  `tinkerex-sync 0.1.0`, sqlite3 3.40.1, `Created`, `/up` → `ok`, `0 nodes, 0 versions`, `doctor`
  clean. It is on the box as `tinkerex-sync:rust-local` (image id `fd3004b481a5`) via
  `docker save | ssh … docker load` — the registry was never involved.
- **§2.2 device door PR: `claude/sync-device-door` in the maker repo.** Not deployed (needs the
  merge and the token). Publishing, measured: `*.tinkerex.home` ALREADY resolves to the NPM front
  proxy at 192.168.1.7 (a wildcard — `sync.tinkerex.home` resolved before anything registered it),
  and NPM forwards only NAMED hosts (it answered its own 404 page for `sync.tinkerex.home`), so the
  one outside step is an NPM proxy host for that name → `http://192.168.1.95:80`; `.local` is a
  line in each client's `/etc/hosts`.
- **§2.3: `R = 4148fcd68ef16bb29f536ced13cd56c0a5237975`**, running since 2026-08-25T02:29Z, image
  id `9115fae48a02`, description label blank (built before the label existed). **Pinned ON THE BOX**
  as `ghcr.io/chaim354/tinkerex-sync:ruby-4148fcd6…` — a local tag, so a later `:latest` pull cannot
  leave the Ruby image dangling for a prune; the ghcr pin waits on the token. **D2 as taken:** the
  Ruby side of `main` differs from `R` by exactly one commit (`5d600bf`, the numeric `expires_at`
  fix — `git log 4148fcd..main -- app lib host Dockerfile …`), so the running image is the better
  rollback target than a fresh build: rolling back lands on exactly what runs today. The reboot
  path gets rehearsed by the device-door deploy, which pulls `:latest` (still Ruby). A Ruby→Ruby
  reboot onto `main` remains the operator's option; nothing here precludes it.
- **Later the same day the operator renewed the PAT** (classic; `write:packages` among much
  broader scopes, no expiry): `api.github.com` 200, ghcr issues a pull/push token for this repo,
  `docker login` succeeds. **§2.3 completed in ghcr:** `:4148fcd6…` and `:latest` both resolve to
  manifest `sha256:9115fae48a02…`, which is the running container's own RepoDigest, so the running
  image IS the registry's `:latest`; `ruby-4148fcd68ef16bb29f536ced13cd56c0a5237975` now points at
  that digest too (`imagetools create`, verified by inspect). The rollback target exists in the
  registry and on the box, and is byte-identical to what runs.
- **§2.4: not run** — waits on this PR merging (the tagging fix is on this branch), then
  `SYNC_PUSH_LATEST=0 SYNC_IMPL=rust bin/build-and-push` from `main`.
- **§3, the rehearsal: RUN**, with the branch-built Rust image and the running Ruby image, both
  local on the box. Archive `tinkerex-sync-20261007T160805Z.tar.gz` (7977 bytes; `integrity_check
  ok — 7 nodes, 3 versions`; 5 users; 3 files in the chunk store). Restored into
  `tinkerex_sync_storage-rehearsal`, `nodes readable … as 1000:1000: 7`. **Rust pass:** `Adopted`,
  `doctor` clean (admin route enabled), `7 nodes, 3 versions`, `/up` ok. Real user (id 3): whoami
  200; `/v1/tree` 2 nodes == `SELECT count(*) FROM nodes WHERE user_id=3 AND deleted=0` → 2.
  Hydration of that user's chunk `d6d45e31…`: `POST /v1/chunks/download` 200, presigned URL on the
  request's own base (`/v1/chunks/blob/3/…`), `GET` 200, 93 bytes, **sha256 equals the hash**.
  Whole corpus with a fresh user: `18 runs, 284 assertions, 0 failures, 0 errors, 0 skips`; after:
  `41 nodes, 38 versions`. **Ruby pass** (`ruby-4148fcd6…`) on the same volume: boots; `bin/rails
  runner` → `41 nodes, 38 versions`; the Rust-issued corpus token: whoami 200 and `/v1/tree` lists
  the 28 nodes the Rust pass created (`Alpha`, `Beta`, `Docs`, `EdgeDir`, `TenancyDir`, …); the real
  user's Rust-issued token: 200, the same 2 nodes; corpus minus 11/14 with a Ruby-issued user:
  `14 runs, 231 assertions, 1 failure` — `15-share-links-edge.yml / create a link with a numeric
  expires_at: expected nil, got 12345`, which IS `5d600bf`'s fix and absent from `R` by construction
  (production answers the same today); after: `71 nodes, 72 versions`. **Rust again:** `Adopted`,
  `71 nodes, 72 versions`, the Ruby-issued token: whoami 200, 27 nodes. Torn down (§3.4).
  *A first attempt was discarded:* a corpus device issued `--name corpus` fails the four lock
  assertions that expect the default name `device`; the volume was re-restored from the same
  archive before the clean run. **Issue corpus devices with the default name.**
- **Not run:** §2.2's deploy and probes, §2.4, §4–§6. **Next, in order:** merge both PRs →
  §2.2's deploy (`bin/kamal accessory reboot sync` pulls `:latest`, still the running Ruby image,
  so the only change is the proxy registration) and its probes → §2.4's push from `main` → §4.

---

## 1. Decisions for the operator (settle before Phase A)

- **D1 — A door for devices.** Expose the accessory through kamal-proxy at
  `sync.tinkerex.local` / `sync.tinkerex.home` (the hostnames this repo's own `deploy.yml`
  already chose). *Recommended: yes, as its own maker PR deployed **before** the swap* (§2.2).
  It is what lets the cutover window measure the headline improvement (the nudge), it lets the
  rehearsal and the production probes run from the Mac without ssh tunnels, and it is the only
  way a desktop client syncs against production at all. The API is device-token gated by design;
  the admin door is `SYNC_ADMIN_TOKEN`-gated; the anonymous share-link redeem becomes reachable,
  which is its purpose. If **no**: skip §2.2, use the in-network probes in §4.5 and the ssh tunnel
  in §3, and record the two device probes as deferred in the cutover PR.
- **D2 — A Ruby→Ruby reboot first.** If the running container has no revision label, or its tag
  is gone from ghcr, there is no verified rollback image. *Recommended: build the Ruby image from
  `main` and reboot onto it before anything else* (§2.3). It also rehearses the exact reboot path
  with no behaviour change beyond the share-link `expires_at` fix merged in #16.
- **D3 — The scheduler.** Keep it **off** through the watch week (the Ruby host never ran these
  jobs in production either). Enable it only after the dry-runs in §5.3, with a maker PR adding
  `SYNC_SCHEDULER: "1"` to the accessory env.
- **D4 — Flipping `bin/sync-server`'s default to `rust`.** Defer to §9 (decommission). The maker
  repo's CI runners are Linux containers (`ci/runner/Dockerfile`) with no cargo; the flip would
  make `bin/ci test-chunk-remote` try to build the binary there. Not part of the cutover.

---

## 2. Phase A — Preparation (no production behaviour changes, except D2's reboot)

### 2.1 This repo: the "cutover prep" PR

- **`Dockerfile.rust`**: install `sqlite3` in the runtime stage, beside `ca-certificates curl`,
  with a comment saying why (finding 0.3.1: the maker repo's `ops/backup-db.sh` and
  `bin/restore-db` run `sqlite3` inside the deployment's image). Mirror the Ruby `Dockerfile`'s
  line.
- **`bin/build-and-push`**: tag the revision as `"$REPO:$REVISION-$SYNC_IMPL"` (so
  `:<sha>-ruby` and `:<sha>-rust` never collide), and push `:latest` only when `SYNC_PUSH_LATEST`
  is not `0`. Default unchanged (`:latest` moves, as today), so existing use is untouched. Print
  both tags at the end. Keep the `org.opencontainers.image.revision` and `.description` labels;
  the description (`tinkerex-sync (ruby)` / `(rust)`) is how a running container names its
  implementation.
- **`crates/tinkerex-sync/README.md`**: the "Gates" section gains the local image smoke below and
  "The image" section records the measured size once built. **`CLAUDE.md` §0 item 4**: point at
  this plan for the cutover.
- **Optional, same PR or the queued task:** `rust-toolchain.toml` pinning the runner's stable
  (1.99.0 on 2026-10-07); #16's only red CI run was a clippy-version gap.
- **Gates** [checkout]: `cargo fmt --all --check`, `cargo clippy --all-targets -- -D warnings`,
  `cargo deny check licenses sources`, `cargo test`, `bin/conformance-rust` (expect
  `18 runs, 284 assertions, 0 failures, 0 errors, 0 skips`). Then the image, on the Mac
  (`linux/amd64`, as `bin/build-and-push` builds it), **without pushing**:

  ```sh
  docker buildx build --platform linux/amd64 -f Dockerfile.rust -t tinkerex-sync:rust-local --load .
  docker image ls tinkerex-sync:rust-local                      # record the size beside the Ruby image's 422 MB
  docker run --rm tinkerex-sync:rust-local tinkerex-sync --version
  docker run --rm --entrypoint sh tinkerex-sync:rust-local -c 'command -v sqlite3 && sqlite3 --version && command -v curl'
  docker run --rm -d --name rust-smoke -p 127.0.0.1:3007:3000 \
    -e STORAGE_BACKEND=local -e SECRET_KEY_BASE=smoke-only tinkerex-sync:rust-local
  docker logs rust-smoke                                        # the entrypoint's migrate prints `Created`
  curl -s http://127.0.0.1:3007/up; echo                        # ok
  docker exec rust-smoke tinkerex-sync stats --brief            # 0 nodes, 0 versions
  docker exec rust-smoke tinkerex-sync doctor
  docker rm -f rust-smoke
  ```

  Paste the size, the `migrate` line and the `/up` body into the PR.

### 2.2 Maker repo: the "device door" PR (D1 = yes)

In `config/deploy.yml`'s `sync:` block add a proxy registration. Kamal 2.12 accepts `proxy:` on an
accessory (`lib/kamal/configuration/accessory.rb`, `running_proxy?`); the keys are the app's
(`bin/kamal docs proxy`). This repo's own `deploy.yml` is the model for the hostnames:

```yaml
    proxy:
      ssl: false
      hosts:
        - sync.tinkerex.local
        - sync.tinkerex.home
      app_port: 3000
      healthcheck:
        path: /up
        interval: 5
```

- Publish the two names the same way the maker's own `<dest>.tinkerex.{local,home}` names are
  published today (`.local` is mDNS on the LAN, `.home` resolves over Tailscale; find where those
  are defined before adding, do not guess). A missing `.home` entry deploys green and 404s off-LAN
  (`deploy.yml`'s own warning).
- Update the `sync:` block's comment ("NO `port:` -> internal-only") and `docs/DEPLOY.md`.
- Tests: `bin/rails test test/deploy_hygiene_test.rb` (it re-derives the accessory-secrets rule
  from the merged config), then `bin/secrets-preflight`.
- Deploy [Mac, maker repo root]: `bin/kamal accessory reboot sync`. This pulls `:latest` (still
  Ruby), stops, removes and starts the container; the maker app's requests during those seconds
  fail as `FileLayer::FetchError` (a 503 in the UI) and recover on their own. Probes:
  `curl -s http://sync.tinkerex.local/up` → `ok` (and `.home` from a Tailscale client); issue a
  probe device [Mac]: `bin/kamal accessory exec sync --reuse "bin/rails sync:device:issue
  EMAIL=cutover-probe@tinkerex-sync.test"` and `curl -H "Authorization: Bearer <token>"
  http://sync.tinkerex.local/v1/devices/whoami` → 200.
- **Record the before-state of the nudge now, on the Ruby host**: point a desktop daemon
  (`maker-cfsyncd <root> <db> <chunks> http://sync.tinkerex.home <token>` on Windows, or the
  macOS/Linux daemon per `../tinkerex-client/CLAUDE.md` §5) at it, change a file through the
  maker UI, and note that the daemon's log never prints `nudge: head_seq N → pulling` (the Ruby
  host refuses its Origin-less `/cable` connection) and that the change arrives on the poll
  fallback, `DEFAULT_POLL` = 2 s (`client/sync-engine/src/daemon.rs`). The cutover PR must state
  this: after the swap, the nudge is the *first time* it works in production.

### 2.3 Establish the rollback image [Mac + box]

```sh
R=$(ssh kamal1@192.168.1.95 "docker inspect tinkerex-sync --format '{{index .Config.Labels \"org.opencontainers.image.revision\"}}'")
ssh kamal1@192.168.1.95 "docker inspect tinkerex-sync --format '{{index .Config.Labels \"org.opencontainers.image.description\"}}'"
echo "running Ruby revision: ${R:-<none>}"
```

- A blank `R` means an image built before the label existed (maker `docs/DEPLOY.md`, "Which build
  is a sidecar accessory running?"). Then, per **D2**: after §2.1 merges, from this repo at `main`
  [Mac]: `SYNC_IMPL=ruby bin/build-and-push` (this moves `:latest` to a Ruby build of `main`,
  which carries only the `expires_at` fix on top of what runs), `bin/kamal accessory reboot sync`
  from the maker repo, verify `/up` and the maker Files page, and re-read `R`.
- With `R` known, pin it so no later build can clobber it, and prove the tag resolves:

  ```sh
  echo "$(bin/secret KAMAL_REGISTRY_PASSWORD 'op://tinkerex/ghcr.io/password')" | docker login ghcr.io -u chaim354 --password-stdin
  docker manifest inspect ghcr.io/chaim354/tinkerex-sync:$R >/dev/null          # or :$R-ruby after §2.1
  docker buildx imagetools create -t ghcr.io/chaim354/tinkerex-sync:ruby-$R ghcr.io/chaim354/tinkerex-sync:$R   # or :$R-ruby, if R was built after §2.1
  docker manifest inspect ghcr.io/chaim354/tinkerex-sync:ruby-$R | head -5
  ```

  `ghcr.io/chaim354/tinkerex-sync:ruby-$R` is **the rollback target** for the rest of this plan.
  Record `R`, the pinned tag and its digest in the cutover PR.

### 2.4 Build and push the Rust image, revision tag only [Mac, this repo at `main`]

```sh
git switch main && git pull --ff-only
SYNC_PUSH_LATEST=0 SYNC_IMPL=rust bin/build-and-push        # pushes :<sha>-rust, leaves :latest alone
RUST=ghcr.io/chaim354/tinkerex-sync:$(git rev-parse HEAD)-rust
docker manifest inspect $RUST | head -5
```

`:latest` still points at Ruby after this step; verify with `docker manifest inspect
ghcr.io/chaim354/tinkerex-sync:latest` (its digest equals `ruby-$R`'s). Record `$RUST` and the
image size the registry reports.

---

## 3. Phase B — The rehearsal on a throwaway volume (rewrite plan §7.1)

The point of the rehearsal is to run **both** images against a copy of the real database and the
real chunk bytes, in both orders, before touching the live volume. It proves the four things the
swap depends on: `migrate` adopts a Rails-created file rather than refusing it; Rust reads
Ruby-written rows and serves Ruby-written bytes; Ruby reads Rust-written rows and authenticates a
Rust-issued token; the counts agree at every step.

### 3.1 Take and restore an archive [Mac, maker repo]

```sh
bin/backup-db sync                          # prints `tinkerex-sync-<stamp>.tar.gz  <size>  <N> nodes`
bin/restore-db sync ~/tinkerex-backups/tinkerex-sync-<stamp>.tar.gz --into rehearsal --yes
```

The restore verifies the archive's `integrity_check` and node count, extracts into
`tinkerex_sync_storage-rehearsal`, and reads the count back through the running (Ruby) image as
its own uid. Keep `N`.

### 3.2 The Rust pass [box]

```sh
SKB=$(docker inspect tinkerex-sync --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^SECRET_KEY_BASE=//p')
docker run -d --name sync-rehearsal -p 127.0.0.1:3005:3000 \
  -v tinkerex_sync_storage-rehearsal:/rails/host/storage \
  -e STORAGE_BACKEND=local -e CHUNK_LOCAL_DIR=/rails/host/storage/chunk-store \
  -e SECRET_KEY_BASE="$SKB" -e SYNC_ADMIN_TOKEN=conformance-corpus-admin-token \
  ghcr.io/chaim354/tinkerex-sync:<sha>-rust
docker logs sync-rehearsal                        # the entrypoint's migrate must print `Adopted`, never `Created`
docker exec sync-rehearsal tinkerex-sync doctor
docker exec sync-rehearsal tinkerex-sync stats --brief     # must equal the archive's `<N> nodes`
curl -s http://127.0.0.1:3005/up; echo                     # ok
```

`SYNC_ADMIN_TOKEN` is the corpus's **fixed** token so files `11-admin.yml` and `14-tenancy.yml`
can run against this throwaway copy; never set that value on the live accessory. `SECRET_KEY_BASE`
is the live one so the blob-URL HMAC is exercised against real bytes; it stays in the shell.

- **Rust reads Ruby's rows and bytes.** Pick a real user:
  `docker exec sync-rehearsal sqlite3 /rails/host/storage/production.sqlite3 "SELECT id, email, head_seq FROM users ORDER BY id LIMIT 5"`
  (the `sqlite3` from §2.1), issue a device for that email (`tinkerex-sync device issue --email
  <email>` reuses the user), and with its token:
  `curl -H "Authorization: Bearer <token>" http://127.0.0.1:3005/v1/tree` → that user's real
  nodes; compare the count with `SELECT count(*) FROM nodes WHERE user_id = <id> AND deleted = 0`.
  Then hydrate one file: `POST /v1/chunks/download` with one of its chunk hashes
  (`conformance/scenarios/09-chunks.yml` shows the body), `GET` the presigned URL it returns, and
  check `sha256sum` of the bytes equals the hash. That is Ruby-written catalog and Ruby-written
  bytes served by Rust.
- **The whole corpus, with a fresh user.** [box] `docker exec sync-rehearsal tinkerex-sync device
  issue --email rehearsal-rust-$(date +%Y%m%d)@tinkerex-sync.test`; [Mac] open a tunnel
  (`ssh -N -L 3005:127.0.0.1:3005 kamal1@192.168.1.95 &`) and in this repo's checkout:

  ```sh
  SYNC_SERVER_URL=http://127.0.0.1:3005 SYNC_DEVICE_TOKEN=<token> RAILS_ENV=test \
    bundle exec ruby -Itest test/conformance_test.rb
  ```

  Expect `18 runs, 284 assertions, 0 failures, 0 errors, 0 skips`. Then `stats --brief` again;
  record the new counts (`N2 nodes, V2 versions`).

### 3.3 The Ruby pass on the same volume [box]

```sh
docker rm -f sync-rehearsal
docker run -d --name sync-rehearsal-ruby -p 127.0.0.1:3006:3000 \
  -v tinkerex_sync_storage-rehearsal:/rails/host/storage \
  -e RAILS_ENV=production -e RAILS_LOG_TO_STDOUT=1 -e CABLE_ADAPTER=async \
  -e STORAGE_BACKEND=local -e CHUNK_LOCAL_DIR=/rails/host/storage/chunk-store \
  -e SECRET_KEY_BASE="$SKB" -e SYNC_ADMIN_TOKEN=conformance-corpus-admin-token \
  ghcr.io/chaim354/tinkerex-sync:ruby-$R
docker logs sync-rehearsal-ruby                   # db:prepare must be a no-op: both migration rows are already there
docker exec sync-rehearsal-ruby bin/rails runner 'puts "#{Node.count} nodes, #{Sync::Version.count} versions"'   # == N2, V2
```

- **Ruby reads Rust's rows and authenticates Rust's token.** With the corpus device's token from
  §3.2: `curl -H "Authorization: Bearer <token>" http://127.0.0.1:3006/v1/devices/whoami` → 200,
  and `/v1/tree` lists the nodes the Rust corpus pass created (the `02-commit.yml` names are in
  that file). With the real user's token from §3.2: `/v1/tree` lists the same real nodes as before.
- **The corpus again, fresh user, minus the two fixed-email files** (`11` and `14` provision fixed
  emails and answer 409 on a database that has run them once):
  `docker exec sync-rehearsal-ruby bin/rails sync:device:issue EMAIL=rehearsal-ruby-$(date +%Y%m%d)@tinkerex-sync.test`
  then [Mac, tunnel on 3006]:

  ```sh
  SYNC_SERVER_URL=http://127.0.0.1:3006 SYNC_DEVICE_TOKEN=<token> RAILS_ENV=test \
    bundle exec ruby -Itest test/conformance_test.rb -n "/scenario:_(0[1-9]|10|12|13|15|16)-/"
  ```

  (the generated test names are `test_conformance_scenario:_02-commit.yml` and so on). Expect
  14 runs, 0 failures, 0 skips.
- **Back to Rust once more** (cheap, and it is the direction the real rollback takes in reverse):
  `docker rm -f sync-rehearsal-ruby`, start `sync-rehearsal` again as in §3.2, and read the Ruby
  pass's nodes with the Ruby-issued token. `stats --brief` equals Ruby's last count.

### 3.4 Tear down and record

```sh
docker rm -f sync-rehearsal sync-rehearsal-ruby
docker volume rm tinkerex_sync_storage-rehearsal
```

Paste into the cutover PR: the archive line, the `Adopted` line, `doctor`, every `stats` /
`runner` count pair, both corpus summaries, and the three readbacks. **Any mismatch stops the
plan here**; the fix goes into this repo first and the rehearsal is repeated from §3.1.

---

## 4. Phase C — The swap (rewrite plan §7.2–7.3)

Pick a quiet hour. The maker app keeps serving reads from its local mirror throughout; only writes
and the two-minute pull touch the sync server, and both fail soft for the seconds the container is
down.

### 4.1 Preflight and backup [Mac, maker repo root]

```sh
bin/secrets-preflight                      # base destination; every secret must resolve non-empty
bin/backup-db sync                         # keep the archive; note `<N> nodes` and the integrity_check
bin/kamal accessory exec sync --reuse "bin/rails runner 'puts \"#{Node.count} nodes, #{Sync::Version.count} versions\"'"
```

Record the counts: they are what `stats --brief` must print after the swap.

### 4.2 Promote the Rust image and reboot [Mac]

```sh
docker buildx imagetools create -t ghcr.io/chaim354/tinkerex-sync:latest $RUST     # $RUST from §2.4
docker manifest inspect ghcr.io/chaim354/tinkerex-sync:latest | head -5             # digest == $RUST's
bin/kamal accessory reboot sync            # pull_image, stop, remove_container, boot (kamal 2.12 cli/accessory.rb)
```

### 4.3 Probes, in this order, each with its expected answer

1. **Which image is running** [box]:
   `docker inspect tinkerex-sync --format '{{index .Config.Labels "org.opencontainers.image.description"}}'`
   → `tinkerex-sync (rust)`; the revision label → the `main` SHA from §2.4.
2. **Boot** [Mac]: `bin/kamal accessory logs sync -n 50` → the entrypoint's `Adopted`, then the
   server listening on `0.0.0.0:3000`. A container in a restart loop here means `migrate` refused
   the live file; go to §6 at once (nothing was written).
3. **In-container health and counts** [Mac]:
   `bin/kamal accessory exec sync --reuse "curl -s localhost:3000/up"` → `ok`;
   `bin/kamal accessory exec sync --reuse "tinkerex-sync stats --brief"` → the §4.1 counts;
   `bin/kamal accessory exec sync --reuse "tinkerex-sync doctor"` → config as the accessory sets it.
4. **The maker app's write journey, through the web UI** (this is also the token-compatibility
   probe: the app authenticates with the per-user `users.sync_device_token` it already holds, so
   no token is extracted): create a folder (`mkdir`), upload a file (`commit` + presigned PUT to the
   blob tier + `finalize`), rename it (`move`), delete it (the cascading delete), restore it from
   Trash (`restore`), download it and compare bytes (`chunks/download` → blob `GET`). Tail
   `bin/kamal app logs -f` meanwhile and expect no `FileLayer::FetchError`.
5. **The two-minute pull**: within two minutes `bin/kamal app logs --grep RemoteChangelogPullJob`
   shows a successful run against the new server.
6. **The admin door** without creating anything. The token is already in the container's env, so
   nothing is copied or printed; on the box:

   ```sh
   docker exec tinkerex-sync sh -c 'curl -s -o /dev/null -w "%{http_code}" -X POST \
     -H "Authorization: Bearer $SYNC_ADMIN_TOKEN" -H "Content-Type: application/json" \
     -d "{\"email\":\"<an existing maker user email>\"}" localhost:3000/v1/admin/libraries'
   ```

   → `409` (`email_taken`). A `503` means the two sides resolved different tokens; a `201` means
   the email was not an existing user's (and a library was just created for it).
7. **Devices** (D1 = yes): the daemon from §2.2 pointed at `http://sync.tinkerex.home`: push a
   file from the mount and see it in the maker UI after the next pull; then change a file in the
   maker UI and watch the daemon print `nudge: head_seq N → pulling` **within a second** of the
   commit. Compare with the 2 s poll recorded in §2.2. Both timings go in the PR.
8. **Share links**: redeem a link created before the swap if one exists, and one created after it
   (`conformance/scenarios/10-share-links.yml` shows the calls). A numeric `expires_at` now means
   no expiry on both servers (#16's Ruby fix).
9. **In-flight blob URLs**: a presigned local blob URL minted by Ruby minutes before the swap still
   verifies on Rust (same `SECRET_KEY_BASE`, same HMAC input; known-answer tested against Ruby's
   OpenSSL). Optional live check: mint one in §4.1 with a short expiry and `GET` it after §4.2.

### 4.4 Record the deploy

- `bin/log deploy --image <sha>-rust --dest sync` [Mac, maker repo].
- Tick §7.2 and §7.3 in `2026-09-30-rust-rewrite.md` with the figures (a PR in this repo), and
  open the **cutover PR** in the maker repo (§4.5), whose body carries every output from §2.3,
  §2.4, §3 and §4.3. `bin/log arc --from-pr N` as it opens.

### 4.5 The maker repo's cutover PR (after the swap, no behaviour change)

- `config/deploy.yml` `sync:` comments: the Ruby-specific explanations (`Sync::Storage::
  LocalChunkStore`, `CABLE_ADAPTER=async`, `RAILS_LOG_TO_STDOUT`) now describe the previous
  image; say so, and that the Rust binary ignores the last two. `docs/DEPLOY.md`: "which build is
  the sync accessory running" reads the **description** label, not only the revision.
- `CLAUDE.md` §3's sync row: "the default arm stays Ruby until the cutover" → cut over on
  `<date>`, Rust image `<sha>-rust`, rollback target `ruby-<R>`.
- **Do not** flip `bin/sync-server`'s default (D4).

---

## 5. Phase D — The watch week (rewrite plan §7.4)

Scheduler **off**. Daily, five minutes:

1. `bin/backup-status` [Mac]: the nightly `sync` archive must appear every morning with a node
   count that tracks `stats`. **The first night after the swap is the real test of §2.1's
   `sqlite3`**; check it the next morning before anything else.
2. `bin/kamal accessory logs sync --since 24h --grep 'ERROR\|response failed'` (the binary's
   `tower_http` trace layer logs a 5xx as `response failed …` at ERROR and ordinary requests only
   at DEBUG; `RUST_LOG=tower_http=debug` on the accessory would show every request) and
   `bin/kamal app logs --since 24h --grep 'FileLayer::FetchError\|ChunkRemote'` (the maker's jobs
   run inside Puma, `SOLID_QUEUE_IN_PUMA: true`, so one log covers the pull job too): expect
   nothing. Any `database is locked` in the sync log is a write-contention signal; note frequency.
3. The volume's size (`docker system df -v` on the box, the `tinkerex_sync_storage` line) and
   `stats --brief`: both should grow with use and never shrink (nothing reaps yet).
4. One manual file round-trip through the maker UI.

At the end of the week, the dry-runs [Mac]:

```sh
bin/kamal accessory exec sync --reuse "tinkerex-sync gc reap-pending --dry-run"
bin/kamal accessory exec sync --reuse "tinkerex-sync gc reap-storage --dry-run"
bin/kamal accessory exec sync --reuse "tinkerex-sync gc retention --dry-run"      # keep_all: prunes nothing
```

Read the lists. Expected: a handful of expired pending commits at most, no storage orphans that a
row still names, nothing from retention. Only then **D3**: a maker PR adding `SYNC_SCHEDULER: "1"`
under the accessory's `env.clear`, `bin/secrets-preflight`, `bin/kamal accessory reboot sync`, and
the next morning's log shows `reap-pending` ran at :30. Tick §7.4.

---

## 6. Rollback (rewrite plan §7.5), at any point after §4.2

Triggers: `migrate` refusing the live file (restart loop in §4.3.2); any failure in the §4.3 journey;
a nightly backup failing; wrong bytes on a hydration; a `database is locked` storm.

```sh
docker buildx imagetools create -t ghcr.io/chaim354/tinkerex-sync:latest ghcr.io/chaim354/tinkerex-sync:ruby-$R
bin/kamal accessory reboot sync
ssh kamal1@192.168.1.95 "docker inspect tinkerex-sync --format '{{index .Config.Labels \"org.opencontainers.image.description\"}}'"   # tinkerex-sync (ruby)
bin/kamal accessory exec sync --reuse "bin/rails runner 'puts \"#{Node.count} nodes, #{Sync::Version.count} versions\"'"
```

Then the §4.3.4 journey once. No data step: rows Rust wrote are ordinary rows to Rails (D2, proven
in §3.3), `migrate` never alters an adopted schema, and the chunk bytes are the same files under
the same keys. Record the rollback with `bin/log note` on the deploy issue, and the reason in this
repo as an issue or a plan correction. The archive from §4.1 is the last resort, restored with
`bin/restore-db sync <archive>` (prompts, pre-backs-up).

---

## 7. After the window

- **§9 of the rewrite plan (decommission)** starts only after a rollback window the operator is
  comfortable with: delete the Ruby engine and host, keep `test/conformance_test.rb` and the
  recorder, `conformance-rust` becomes `conformance`, rewrite this repo's `CLAUDE.md` and
  `README.md`, mark `docs/SYNC_SERVER.md` historical.
- Maker repo, with §9: flip `bin/sync-server`'s default to `rust` (needs cargo in
  `ci/runner/Dockerfile` or `TINKEREX_SYNC_BIN` on the runners), then delete the Ruby arm;
  drop `CABLE_ADAPTER` and `RAILS_LOG_TO_STDOUT` from the accessory env.
- Client repo: `CLAUDE.md` §7's row ("the nudge starts working at that cutover") becomes a
  statement with the measured latency from §4.3.7; the CI legs that point devices at
  `http://192.168.1.95` point at the door from §2.2.

---

## 8. What each PR body must contain

The rewrite plan's §8 entries are the model: the figure, the date, the box, and what was *not* run.

| PR | must carry |
|---|---|
| prep (this repo, §2.1) | the gate figures; the image size; the `Created` line; the `/up` body; the `sqlite3 --version` line |
| device door (maker, §2.2) | `/up` through the proxy; `whoami` 200; the before-state: no `nudge:` line, 2 s poll |
| cutover (maker, §4.5) | `R` and the pinned tag's digest; `$RUST` and its digest; every §3 count pair and both corpus summaries; the three readbacks; the §4.3 answers in order with the nudge timing; the `bin/log deploy` number |
| §7 bookkeeping (this repo) | §7.1–7.3 ticked with the same figures, §7.4 after the week, §7.5 "not needed" or the rollback record |

---

## 9. Risks the agent should hold in mind

- **`migrate` refuses the live file.** It adopts only a database with both `schema_migrations`
  rows (`20260101000001`, `20260101000002`) and every table present, and refuses a half-migrated
  one (`crates/tinkerex-sync/src/schema/mod.rs`). Production was created by those two migrations
  and nothing since, so §3.2 should print `Adopted`; if the rehearsal refuses, the live swap would
  too, and the fix is in this repo, never by hand on the volume.
- **The nightly backup** (finding 0.3.1) is the one failure that would stay silent until a restore
  was needed; §5.1's first-morning check exists for it.
- **Blob URLs behind the proxy.** The binary builds the local blob URL from `x-forwarded-proto`
  and `x-forwarded-host` when present (`src/http/mod.rs`), else from the request's own host, so
  devices through kamal-proxy get `http://sync.tinkerex.home/...` and the maker app gets
  `http://tinkerex-sync:3000/...`. If the door is ever TLS-terminated, set `CHUNK_PUBLIC_URL` or
  confirm the forwarded headers arrive.
- **New status codes.** The binary answers 413 for an over-limit body (64 MiB blob, 16 MiB commit,
  1 MiB elsewhere) and 408 after 120 s, which the Ruby host never sent; the maker transport maps any
  unknown code to `FileLayer::FetchError` (`chunk_remote/transport.rb`), a 503 in the UI, which
  is the right failure for both.
- **Write contention.** SQLite `BEGIN IMMEDIATE` under the user row lock serialises a user's
  writes; the maker app and one daemon are far below where that matters, but §5.2 watches for it.
- **Tag discipline.** Every image reference in this plan is a revision tag or the pinned
  `ruby-$R`; `:latest` is only ever *written* by §4.2 and §6, never read to find out what runs.
  The running container's labels are the only answer to "what is deployed".
