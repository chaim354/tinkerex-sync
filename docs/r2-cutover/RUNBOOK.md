# R2 cutover runbook — SeaweedFS → Cloudflare R2

> **HISTORICAL — moved here from `chaim354/tinkerex` (`scripts/r2-cutover/`) on 2026-11-10, and
> not re-run since it was written (2026-06).** It dates from when the sync engine was Ruby and ran
> inside the maker app, so its "Rails box" and "Rails DB" mean the sync server, and every
> `config/…` and `docs/…` path below is in **`chaim354/tinkerex`**: the design is its
> [`docs/r2-migration.md`](https://github.com/chaim354/tinkerex/blob/main/docs/r2-migration.md)
> (also marked historical), and the `sync` accessory's env lives in its `config/deploy.yml`.
>
> **Checked on the move:**
> - **Still true.** This server reads the same `STORAGE_BACKEND` and `CHUNK_*` variables, and keys
>   chunks `chunks/{user_id}/{hash}` (`crates/tinkerex-sync/src/store/mod.rs`), so the copy and
>   verify logic in `migrate-chunks.sh` still matches. `tinkerex-client` still has
>   `client/sync-engine/examples/presigned_roundtrip.rs`, which `smoke.sh` runs.
> - **No longer true.** The deployed `sync` accessory stores chunks on **local disk**
>   (`STORAGE_BACKEND=local`), not on SeaweedFS, so the migration's source side, the `SEAWEED_*`
>   half of `r2.env.example`, needs rewriting before this is used. Secrets are resolved by
>   `bin/secret` and never `export`ed (tinkerex `CLAUDE.md` §13), unlike
>   `config/deploy.r2.example.yml`'s advice.
>
> Read it for the reasoning (idempotent, hash-verified copy; untouched source; env-only switch),
> and re-verify each step before running it.

Push-button, ordered, copy-pasteable steps to move the managed deployment's **chunk
storage** from the SeaweedFS box to a Cloudflare **R2** bucket. The switch is
**config-only on the server** (`STORAGE_BACKEND=s3` + `CHUNK_*`); chunks are immutable +
content-addressed, so the data migration is an **idempotent `rclone copy`** of the
`chunks/` keyspace.

> Source of truth for the design: `docs/r2-migration.md` (§2 CORS, §3 steps, §5 latency,
> §6 checklist, §3.6 rollback). This runbook turns that prose into a single executable
> path using the tooling in this directory.

**Why this is safe** — see [§"Safety model"](#safety-model) at the bottom. In short:
content-addressed → copy is idempotent/resumable + hash-verifiable; the source is never
modified, so rollback data stays intact; the cutover is just env, reversible with one
`kamal deploy`.

---

## 0. What YOU must supply

| Need | Where to get it |
|---|---|
| **Cloudflare Account ID** | `wrangler whoami`, or dashboard account home. Endpoint = `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`. |
| **R2 API token** (Access Key ID + Secret) | R2 → Manage R2 API Tokens → Create (Object Read & Write, **scoped to the bucket**). Secret shown once. |
| **Production web origin** | The exact `scheme://host(:port)` the web UI loads from — for `cors.json`. Only needed if the web UI will hit R2. |
| **SeaweedFS S3 creds** | The current source store creds (`admin`/secret in the LAN deploy). |
| **Deploy host access** | Your normal Kamal deploy shell (`~/kamalw` / `kamal`) per `docs/DEPLOY.md`. |

Tooling needed locally: `rclone` (migration), `bash`, and either `wrangler` or `aws` CLI
(CORS — optional, can use the dashboard instead). `cargo` (smoke test).

---

## 1. Create the bucket + scoped token

In the Cloudflare dashboard (or `wrangler`):

1. **R2 → Create bucket** → name `maker-chunks-prod` (location hint near your users / Rails host).
2. **R2 → Manage R2 API Tokens → Create API token** → permission **Object Read & Write**,
   **scoped to `maker-chunks-prod`**. Copy the **Access Key ID** + **Secret Access Key** now.

Note your **Account ID** → endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

---

## 2. Configure the cutover env (local)

```sh
cd docs/r2-cutover
cp r2.env.example r2.env
# edit r2.env: fill SEAWEED_* (source) and R2_* (destination) — real creds, NOT committed.
set -a; . ./r2.env; set +a      # export all of it into this shell
```

`r2.env` is gitignored. It feeds both the migration script and (optionally) the CORS apply.

---

## 3. (web UI only) Apply the CORS policy

Skip if the web UI is not yet pointed at R2 — the desktop/daemon client doesn't need CORS.

```sh
# Edit cors.json: replace "https://app.yourdomain.com" with your REAL web origin.
# (Add http://localhost:3000 as a 2nd origin only while developing the web UI vs R2.)
R2_BUCKET=maker-chunks-prod ./apply-cors.sh
```

`apply-cors.sh` refuses to apply while the placeholder origin or a wildcard `*` is still
present. It uses `wrangler` if present, else `aws s3api put-bucket-cors`, else tells you to
use the dashboard. **A CORS mistake is only catchable in a real browser** — after applying,
do one browser upload/download against R2 before cutting the web UI over.

---

## 4. Bulk migrate the chunk keyspace (BEFORE the flip)

The source stays live and serving during this — it's a non-destructive copy.

```sh
./migrate-chunks.sh dry-run        # show what WOULD copy (no writes)
./migrate-chunks.sh copy           # bulk copy SeaweedFS -> R2 (idempotent/resumable)
./migrate-chunks.sh check          # verify by hash (authoritative for content-addressed data)
```

`check` exits non-zero on any mismatch — and also on a run it could not honestly call a
verification: an **empty source keyspace** (a wrong bucket/endpoint/prefix, which bare
`rclone check` reports as "0 differences found" and exits 0 for), or objects rclone could
only compare **by size** because their ETag is not a usable md5. On success it prints
`N/N chunks verified by hash`, with N the real source object count.

For a brand-new managed deploy with no prior data, **skip this whole section** — `check`
deliberately FAILS on an empty source rather than passing over nothing.

---

## 5. Set the server env (`config/deploy.yml`)

Edit `config/deploy.yml`'s `env:` block to the R2 values. The exact block is in
**`config/deploy.r2.example.yml`** — copy its `env.clear` chunk-storage lines + keep
`CHUNK_SECRET_ACCESS_KEY` in `env.secret`. Concretely, change:

```yaml
# env.clear:
STORAGE_BACKEND: s3
CHUNK_ENDPOINT: https://<ACCOUNT_ID>.r2.cloudflarestorage.com   # was http://192.168.1.7:8333
CHUNK_BUCKET: maker-chunks-prod                                 # was my-bucket
CHUNK_REGION: auto                                              # was us-east-1
CHUNK_ACCESS_KEY_ID: <R2 token Access Key ID>                  # was admin
# CHUNK_SECRET_ACCESS_KEY stays in env.secret, sourced from the shell (next step).
```

`aws-sdk-s3` is already in the Gemfile (`gem "aws-sdk-s3", require: false`), so no Gemfile change.

---

## 6. Deploy via Kamal

```sh
export CHUNK_SECRET_ACCESS_KEY=<R2 token Secret Access Key>   # sourced by .kamal/secrets
~/kamalw deploy        # or: kamal deploy   (rsync the tree first per docs/DEPLOY.md)
```

The Rails box only signs URLs (local HMAC) and never contacts the store, so it needs no
network reach to R2 — but **every client device does** (clients PUT/GET R2 directly). R2's
endpoint is public HTTPS.

---

## 7. Smoke test the data plane (real bytes through R2)

```sh
SERVER_URL=https://<your-server> ./smoke.sh
```

Expect `PRESIGNED ROUNDTRIP OK` (device A → R2 → device B, byte-for-byte). This confirms
presign + PUT + GET + `head_object` verify all work against R2. If it fails, **roll back**
(§9) before proceeding. Optionally re-run the latency harness (`docs/r2-migration.md` §5).

It also prints a **`store identity`** line — the endpoint and bucket the server actually
presigned against, read out of a real presigned URL (path-style, so origin + first path
segment carry both; the signed query string is never printed). **Run this with `r2.env`
sourced** (§2) and `smoke.sh` compares that identity to `R2_ENDPOINT`/`R2_BUCKET` and fails on
a mismatch; without them it prints a NOTICE saying the identity was shown but not checked.
That comparison is the *only* thing anywhere that cross-checks the server's `CHUNK_BUCKET`
against the bucket `migrate-chunks.sh` filled — a byte-perfect roundtrip against the wrong
bucket looks exactly like a byte-perfect roundtrip against the right one.

---

## 8. Final incremental copy (RIGHT AFTER the flip) + monitor

Chunks may have been written to SeaweedFS between the bulk copy (§4) and the cutover (§6).
Top R2 up so nothing is missed:

```sh
cd docs/r2-cutover && set -a; . ./r2.env; set +a
./migrate-chunks.sh incremental    # SeaweedFS -> R2 top-up (idempotent)
./migrate-chunks.sh check          # re-verify by hash
```

**Monitor** for a few days: client sync/hydrate success, server logs, R2 metrics
(Class A/B ops, storage). **Keep the SeaweedFS bucket untouched as the rollback source**
until you're confident — do **not** delete source data yet.

---

## 9. Rollback (fast — it's just env)

The control plane (Rails DB: tree/versions/manifests/changelog) stores **hashes, not URLs**,
so it is unaffected by the storage backend — no DB rollback is ever involved.

1. **Backfill SeaweedFS first** with any chunks that landed *only* in R2 during the R2
   window (otherwise files whose new chunks are R2-only would fail to hydrate on SeaweedFS):
   ```sh
   cd docs/r2-cutover && set -a; . ./r2.env; set +a
   ./migrate-chunks.sh rollback     # reverse copy R2 -> SeaweedFS (R2 source untouched)
   ```
2. Revert `config/deploy.yml`'s `CHUNK_*` to the SeaweedFS values (or `git checkout` the
   prior file), re-export the SeaweedFS secret, and redeploy:
   ```sh
   export CHUNK_SECRET_ACCESS_KEY=<SeaweedFS secret>
   ~/kamalw deploy
   ```
   Clients go back to presigned-SeaweedFS URLs on their next commit/hydrate.

---

## Cutover order (one glance)

```
1  create R2 bucket + scoped Object-R/W token
2  cp r2.env.example r2.env; fill; source it
3  (web UI) edit cors.json origin; ./apply-cors.sh; browser-test
4  ./migrate-chunks.sh dry-run -> copy -> check          (BEFORE the flip; source live)
5  edit config/deploy.yml env -> R2 (per deploy.r2.example.yml)
6  export CHUNK_SECRET_ACCESS_KEY=<R2 secret>; kamal deploy   (the flip)
7  SERVER_URL=... ./smoke.sh  -> PRESIGNED ROUNDTRIP OK
8  ./migrate-chunks.sh incremental -> check               (top-up after the flip); monitor
9  rollback if needed: ./migrate-chunks.sh rollback -> revert env -> deploy
   (keep SeaweedFS untouched for a few days as the rollback source)
```

---

## Safety model

- **Idempotent + resumable.** Chunks are immutable and content-addressed
  (`chunks/<user_id>/<sha256>`, bytes == hash). `rclone copy` transfers only what's missing
  at the destination, so a re-run fills gaps and a completed run is a no-op. A partial copy
  resumes cleanly.
- **Hash-authoritative verification — but the EXIT CODE is not that claim.** For
  content-addressed data a hash match *is* proof the destination object is the correct bytes.
  `rclone check` alone does not establish one: verified against rclone **v1.74.3** source, it
  exits 0 in three further cases — **zero objects on both sides** ("0 differences found"), an
  object whose **ETag is not a usable md5** (multipart or SSE-KMS: counted as a match,
  compared by SIZE ALONE, surfaced only as a `NOTICE: N hashes could not be checked`), and
  **`--size-only`**, which short-circuits before the hash check and is settable from the very
  environment this tooling is configured through. `=` lines in rclone's output look identical
  in all four cases, so counting them proves nothing on its own. `migrate-chunks.sh check`
  therefore counts matches against the source's **own** object count, refuses an empty source
  keyspace **by name**, refuses any run where rclone reported unchecked hashes, and prints
  `N/N chunks verified by hash`. **Fragile, pinned to a version:** the unchecked-hash guard
  parses a LOG STRING because rclone exposes no exit code and no machine-readable channel for
  it — re-verify it on an rclone upgrade.
- **No rclone overrides from the environment.** rclone reads every one of its flags from
  `RCLONE_<FLAG>`, and — probed against v1.74.3 — **the environment beats an explicit
  command-line flag**: `RCLONE_SIZE_ONLY=true rclone check --size-only=false` still compares by
  size only, and `RCLONE_DRY_RUN=true rclone copy --dry-run=false` still copies nothing and
  exits 0. Since `r2.env` is sourced into the shell these commands run in, `migrate-chunks.sh`
  **refuses to run** (exit 2, naming the variable) if any `RCLONE_*` variable other than
  `RCLONE_TRANSFERS`/`RCLONE_CHECKERS` is set. If a command stops with that message, unset what
  it names — do not reach for a negating flag, which does not work.
- **Non-destructive / rollback-preserving.** `copy`/`check` never modify the source. The
  SeaweedFS data stays intact and serviceable throughout, so rollback is always available.
  The reverse `rollback` copy backfills R2-only chunks before you revert env.
- **Reversible cutover.** The flip is env-only; revert + `kamal deploy` and clients return to
  the old store on their next request. The DB stores hashes (never URLs), so it's untouched.
- **No secrets in git.** `migrate-chunks.sh` configures rclone purely via
  `RCLONE_CONFIG_*` env vars (no rclone.conf, no command-line secrets, avoiding the
  connection-string colon-parsing pitfall). Creds live in `r2.env` (gitignored) and the
  Kamal `env.secret` (sourced from the shell). `cors.json` carries only a placeholder origin.
- **Dry-run first, and only when asked for.** `migrate-chunks.sh dry-run` shows exactly what
  would move before any bytes are written; every command prints a loud FROM/TO banner. A stray
  `RCLONE_DRY_RUN=true` cannot silently turn a real `copy` into a no-op that still prints
  "Copy complete." — the environment guard above refuses the run outright.
```
