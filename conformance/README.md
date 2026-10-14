# The conformance corpus

This repository is a standalone sync server — one Rust binary, `crates/tinkerex-sync` — exposing a
28-route v1 HTTP API beside a readiness probe and a WebSocket (`tinkerex-sync routes` prints all
30, and `routes.txt` here is that list, checked in; count it yourself with the command at the end
of this document). The server was a Rails engine and host until 2026, and was rewritten in Rust.
`conformance/` exists so that rewrite could be graded against something other than "port the Ruby
tests," which would have bound the two implementations together by shared code rather than by the
wire — the same failure shape as a fake that shares the real code's own bug (see below). The Ruby
server is gone (Phase 6 of `docs/superpowers/plans/2026-09-30-rust-rewrite.md`); the corpus, and
its Ruby verifier and recorder, stay — so the binary is still graded from outside its own language.
Scenario descriptions name the Ruby classes they were first recorded against (`Sync::Search`,
`Sync::Locks`, ...); read those where `main` last had them, `git show 36bb82e:app/...`.

**This document does not restate the wire protocol.** For what each endpoint means, its request/
response shape, and the sync model in general, read `docs/sync-protocol.md` in the sibling
`chaim354/tinkerex` repository (`../tinkerex/docs/sync-protocol.md` from here, if you have it
checked out alongside this one). This document is about the *corpus* — the file format, the
matching rules, and how to run it — not about what the endpoints do.

**Your reader is an implementer who does not read Ruby.** Everything below is written so you can
write your own runner from this document alone, without opening `runner.rb`. Where Ruby source is
the ultimate authority (the matcher's exact behavior, the JSON Schema), this document says so and
names the file — but it does not make you go read that file to understand the format.

## At a glance

```
conformance/
  README.md         this file
  schema.json        the machine-readable, normative shape of one scenario file (JSON Schema, draft 2020-12)
  runner.rb          the Ruby matcher implementation (Conformance::Matcher) -- the reference, not the spec
  routes.txt         every route the server serves -- `tinkerex-sync routes`, checked in (see the coverage check below)
  scenarios/
    01-enrolment.yml
    02-commit.yml
    ...              sixteen scenario files today, run in filename order (see "Execution semantics" below)
    10-share-links.yml
    11-admin.yml
    12-edge-cases.yml
    ...              12-16 pin the refusals, the fast-forward edges, tenancy, share-link edges and the blob tier
    16-blob-tier.yml

bin/conformance-record    records a scenario's expected responses from a real, running server
test/conformance_test.rb  the verifier -- replays every scenario against SYNC_SERVER_URL and checks it
bin/conformance           boots the binary on a fresh database and runs the verifier against it (CI's job)
```

## Why this corpus exists

**Authored requests, recorded responses.** A human writes the `request:` half of every step by
hand — method, path, query, body. Nothing ever writes that half mechanically. The `expect:` half
is the opposite: it is filled in by `bin/conformance-record` from whatever a real, running server
actually answered, never hand-typed from what someone believes the server *should* answer.

The reason this split matters is not stylistic. An expectation written by the same mind that wrote
the implementation tends to agree with the implementation — including in the places where the
implementation is wrong. A hand-typed "the server returns `{status: 200, node_id: "..."}`" is a
restatement of what the author already believes, and a restated belief cannot catch a mistaken
belief. A *recorded* response is what the server actually said on the wire, which a human then
reviews for correctness — a fundamentally different act than composing the expectation from
memory.

This corpus's own comments name a concrete precedent for what goes wrong otherwise: in the sibling
monorepo, a fake S3 double decoded a copy-source header with the inverse of the encoding the real
adapter used to write it — two independent implementations of the same misunderstanding, agreeing
with each other perfectly. 79 of 80 tests stayed green over silent, permanent data loss on any
filename containing a space, because the test and the code under test shared one wrong assumption
about how a header should be encoded. A fake that shares the real code's own bug is invisible to
both. The fix is the same fix as here: assert what a real, independent system actually said,
never a round trip through a shared belief about what it should say.

`bin/conformance-record` still makes one kind of guess: a value the server could not repeat on a
different run — a database id, a timestamp, a freshly-minted secret — is recorded as `{"$type":
"..."}` rather than as the literal it happened to be this time (see "The matcher vocabulary"
below). Every `$type` the recorder writes is printed at the end of a recording run, because a
`$type` is an admission that the wire contract isn't pinned down at that point, and a human should
look at each one and decide whether it deserves to be tightened into a `$capture`/`$ref` pair, or
a literal, instead. "Reviewing what got written" below covers this in more depth, with two real
examples.

## A worked example: `to_root`

`conformance/scenarios/05-trash.yml` is worth reading end to end as the clearest illustration of
what this corpus is *for*. Its centerpiece:

```yaml
- name: restore child.txt WITHOUT to_root -- its parent (Temp) is still tombstoned,
    so this is a 409, not a silent resurrection into a deleted tree
  request:
    method: POST
    path: "/v1/trash/00000000-0000-4000-8000-000000005002/restore"
  expect:
    status: 409
    body:
      error: parent_deleted
- name: restore child.txt WITH to_root -- succeeds, re-parented to the library root;
    parent_node_id comes back explicitly null, not merely absent from the response
  request:
    method: POST
    path: "/v1/trash/00000000-0000-4000-8000-000000005002/restore"
    body:
      to_root: true
  expect:
    status: 200
    body:
      node_id: 00000000-0000-4000-8000-000000005002
      parent_node_id:
      seq:
        "$type": integer
```

Restoring a tombstoned node whose *parent* is itself still tombstoned is an orphan restore. There
are two real client implementations of the sync protocol in the tinkerex ecosystem, and they
disagree about what to do about it: one sends `to_root: true` unconditionally; the other posts an
empty body and always takes the 409. The scenario file does not adjudicate which client is
"correct" — it pins **both** arms of what the *server* actually does, as two separate, real,
recorded HTTP exchanges. An implementation — the Rust rewrite this corpus graded before it replaced
the Ruby server, or any later one — cannot silently pick one arm and drop the other without a test
naming the one it dropped. That is
the whole value proposition of this corpus in one example: not "does the server work," but "does
the server draw this exact, previously-discovered line in the exact place it drew it before,"
including the branches nobody would think to write from a fresh reading of a spec.

The same file also pins two smaller, easy-to-get-wrong shapes worth noting because they are
general lessons, not just local to trash: `parent_node_id` on a successful `to_root` restore comes
back as an explicit JSON `null`, not merely an absent key — those are different answers on the wire
and the matcher can tell them apart (see `$absent` below). And restoring an already-live node is an
idempotent success (`seq: null` — nothing to append to the changelog) rather than a 404 or a 422.

## The scenario file format

The complete, machine-readable shape is `conformance/schema.json` (JSON Schema, draft 2020-12).
Validate against it rather than re-deriving these rules from scratch; what follows is the same
shape in prose, plus the parts a schema can't say (why the shapes are what they are).

A scenario file is one YAML document:

```yaml
name: <string>            # a stable identifier, e.g. used to label failures
description: <string>     # required -- what property this scenario demonstrates (see below)
steps:
  - name: <string>
    request:
      method: GET | POST | PUT | DELETE
      path: <string>
      query: {...}         # optional
      body: {...}          # optional, any shape -- 28 routes, 28 different bodies
      headers: {...}        # optional, extra headers beyond the runner's own defaults
    expect:
      status: <integer>
      body: <matcher value>  # optional -- see "The matcher vocabulary"
```

No additional top-level or step-level keys are allowed (`additionalProperties: false` throughout
the schema) — a typo in a key name fails loudly at validation, not silently as an ignored field.

**`description` is required, not optional, on purpose.** A scenario earns its place in this corpus
by being reviewed by a human who read a real recorded response and decided it was correct; the
description is where that reviewer states what property the scenario demonstrates. A scenario
without one hasn't been reviewed, by definition.

**`request.method`** is one of exactly four values today: `GET`, `POST`, `PUT`, `DELETE` — the
verbs this API actually uses (there is no `PATCH` anywhere in it). This is a closed enum
deliberately: a typo'd verb should fail schema validation immediately, not turn into a confusing
HTTP error against a live server three steps later.

**`request.path`** is one of exactly two shapes:

1. An absolute path starting with `/`, e.g. `/v1/nodes/{{node}}/move` — may contain `{{name}}`
   placeholders anywhere inside it (see "Interpolation" below).
2. Exactly one bare `{{name}}` placeholder and nothing else before or after it — no leading `/`,
   no trailing text. This exists for exactly one case: the two presigned chunk-blob endpoints
   (`PUT`/`GET /v1/chunks/blob/:user_id/:hash`) hand back one complete, already-signed URL —
   scheme, host, path, and query string bundled together — because there is no separate field for
   the signature and expiry query parameters, and no secret this corpus has access to for
   constructing a valid signature by hand. When a step's `{{name}}` resolves to a full URL like
   this, **send the request to that URL directly — do not resolve it against the server's own base
   URL first.** (Ruby's `URI.join(base, absolute_url)` happens to do the right thing here already,
   because RFC 3986 resolution of an absolute URI against any base just returns the absolute URI
   unchanged — verified directly: `URI.join(URI("http://a"), "http://b/x?y=1")` returns
   `http://b/x?y=1`, not something joined onto `http://a`. A hand-rolled URL joiner in another
   language needs to reproduce that same "already-absolute wins outright" behavior, or it will
   silently send the presigned request to the wrong host.)

   A path that is a placeholder *plus* other text (`{{x}}/move`, no leading `/`) is rejected by the
   schema — only a bare `/...` or an exact `{{name}}` validates, so a mistyped relative path is
   caught before a single request goes out.

**`request.query`** and **`request.body`** are otherwise unconstrained by the schema beyond basic
JSON types — 28 routes, 28 different bodies, and this format does not attempt a per-endpoint
shape (that's what `docs/sync-protocol.md` is for). String values inside either may contain
`{{name}}` placeholders.

**How `request.body` gets serialized onto the wire depends on its own shape, and getting this
wrong silently corrupts bytes rather than raising anything.** An object or array body is
JSON-encoded, with `Content-Type: application/json` — every body this corpus sends except the blob
PUT's bytes. A **bare
string** body (`body: drawing bytes`, YAML for a plain scalar string, not an object) is sent
**verbatim, byte for byte, with no JSON encoding at all**, and `Content-Type:
application/octet-stream` — this is the one shape used for the two presigned chunk-blob `PUT`
requests, whose body is real file content. Getting this backwards — JSON-encoding a string body
the way every other endpoint's object body is encoded — wraps it in quotes on the wire
(`"drawing bytes"`, 15 bytes, not 13): invisible if nothing ever asserts a byte on the far side of
a round trip, and exactly the bug `09-chunks.yml` exists to catch, by uploading a literal string
and asserting the *exact same literal* comes back from a hydration `GET` a few steps later — a
`Content-Type` header decides which encoding rule applies, so branch on the value's own type
(string vs. object/array), not on which endpoint you happen to be calling.

**The mirror rule governs how to turn an HTTP *response* into the "actual value" the matcher
compares `expect.body` against**, and it is symmetric with the request-encoding rule above: when
the response's `Content-Type` — its media type only, ignoring any `; charset=...` or other
parameter (verified: Ruby's own `Content-Type` parsing already discards parameters here, so
`"application/json; charset=utf-8"` and `"application/json"` are treated identically) — is exactly
`application/json`, parse the body as JSON and match the parsed value structurally, per "The
matcher vocabulary" below. For any other `Content-Type` (today, only the chunk-blob `GET`'s
`application/octet-stream`), treat the **raw response body text itself** as the actual value — a
plain string, matched the same way any other literal string is matched. This is why
`09-chunks.yml`'s hydration step can write `expect: {status: 200, body: hydration round trip bytes
exact}` — a bare string, not `{"body": "..."}` — and have it mean exactly what it looks like it
means. A response with no bytes at all (e.g. `DELETE /v1/share_links/:id`'s `204`) is simply not
compared: `expect.body` is optional precisely for this case, and a step that omits it asserts
nothing about the body, whatever it is.

**`request.headers`** carries extra headers beyond whatever the runner supplies by default. Every
request gets three headers unless a step overrides them: `Content-Type` (per the body-type rule
above), `Accept: application/json`, and `Authorization: Bearer <SYNC_DEVICE_TOKEN>` — one token for
the whole run, from the environment, not from the scenario file. `request.headers` is merged on top
of those three **by key**, not substituted wholesale, so a step can override just one of them (in
practice, only `Authorization` ever is — see "Interpolation" below for the second-device case this
exists for) while the other two defaults still apply. Rarely needed otherwise; string values here
are interpolated the same as `path`/`query`/`body`.

**`expect.status`** is a plain integer, matched by exact equality. There is no special form for
it: every endpoint returns a fixed, known status per outcome, so a status that genuinely varies
from run to run would be a sign the scenario is testing the wrong thing.

**`expect.body`** is optional (some responses have no body, e.g. `DELETE /v1/share_links/:id`
returns `204`) and, when present, is matched by the vocabulary in the next section.

## The matcher vocabulary

An `expect.body` is compared against the actual response's body — parsed as JSON when the response
says it is JSON, or else the raw response text itself (see the request/response encoding rule
above) — recursively. At every position the recorded value is one of five things:

| Form | Written as | Matches | Refuses |
|---|---|---|---|
| Literal | `42`, `"foo"`, `true`, `null`, an array, a plain object | Exactly that value (objects/arrays recursively) | Any different value; an object with an extra or missing key; an array of the wrong length |
| Capture | `{"$capture": "name"}` | Any value that is *present* — and remembers it under `name` for later `$ref`/`{{name}}` use | The key being **missing** entirely |
| Reference | `{"$ref": "name"}` | A value equal to whatever `name` was bound to earlier in this file | A name never captured earlier (an **error**, not a silent pass); a present value unequal to the bound one |
| Type | `{"$type": "string\|integer\|boolean\|array\|object\|null"}` | Any value of that runtime type | A value of the wrong type; a **missing key**, for every type name — including `"null"` |
| Absence | `{"$absent": true}` | The key being **missing** entirely | A present key, whatever its value — including an explicit `null` |

Five forms, deliberately, and no more without a strong argument for a sixth: a matcher's whole job
is refusing things, and each additional form is one more way an over-permissive matcher can
accidentally shrug at a real regression.

**A recorded object is matched exactly, in both directions — not a subset match.** Every key the
scenario names must be present and correct in the actual response (checked first), *and* the
actual response must not carry any key the scenario didn't name (checked second, over
`actual.keys - expected.keys`). This second direction is the one worth pausing on: for a wire
contract, a field the server started sending that nobody reviewed *is* a contract change, and a
matcher that only checks "everything I named is right" would let a server bolt an unreviewed field
onto a response with the corpus none the wiser. Concretely: `{"a": 1}` matches an actual body of
`{"a": 1}`, but **not** `{"a": 1, "b": 2}` — the extra key `b` is itself the mismatch, not a bonus.
The same shape applies to arrays via a plain length check (`expected.size == actual.size`) before
comparing elements pairwise by index.

**A missing key and an explicit `null` are different answers, and the vocabulary can tell them
apart.** A literal `null` in the expectation matches only a key that is *present* and holds JSON
`null` — it does **not** match a key that's absent altogether. `$absent: true` is the mirror image:
it matches only a key that's missing, and refuses a present key even when that key's own value is
`null`. This distinction is not academic — the `to_root` example above is exactly a case where a
node's `parent_node_id` comes back explicit `null` (re-parented to the root) rather than merely not
being in the response, and a matcher that conflated the two would have nothing to say about that
difference.

**`$type: null` demands presence, the same as every other `$type`.** It is easy to read `$type:
null` as "this is allowed to be absent," but it is not the same question `$absent` asks: it demands
the key be *present* with an explicit JSON `null`. A missing key fails a `$type: null` check the
same way it fails `$type: integer` — there is no runtime type that a missing key satisfies.

**A hash counts as one of the four special forms only when it has exactly one key, and that key is
one of the four names above.** `{"$capture": "node"}` is a capture. `{"$capture": "node", "extra":
1}` is **not** — it has two keys, so it is an ordinary object, matched key by key like anything
else (which means the actual value would need a literal key named `"$capture"` holding the literal
string `"node"`, an object shape no real response is likely to have — this is an edge case the
format doesn't bother forbidding outright, because no human is likely to author it by accident).
This is what lets `{"id": {"$capture": "node"}}`'s *inner* single-key hash bind a capture while the
*outer*, multi-key hash around it is matched structurally as a normal object.

**A `$ref` to a name nothing captured is an error, not a silent pass, and neither is an unbound
`{{name}}` interpolation** (see next section) — both fail loudly, naming what wasn't found, rather
than quietly treating "I don't know what this should be" as "anything goes."

**A mismatch stops the whole comparison at the first disagreement** — there is no "collect every
mismatch and report them all" mode, and every failure names the JSON path where it happened (e.g.
`body.changes[0].node_id: expected "abc" (bound to "node_id"), got "xyz"`). Once one key's shape
disagrees, there's nothing underneath it worth continuing to check.

Real examples pulled directly from the corpus, each demonstrating one form:

```yaml
# literal (01-enrolment.yml) -- this user has genuinely never made a mutation yet
head_seq: 0

# $capture (08-locks.yml) -- remember the server-assigned expiry for a later step to check against
expires_at:
  "$capture": lock_a_expires_at

# $ref (08-locks.yml, the very next step) -- device B's own lock attempt must see the SAME
# expires_at device A's lock got, proving B did not steal or refresh it
expires_at:
  "$ref": lock_a_expires_at

# $type (01-enrolment.yml) -- a database id, new on every run
device_id:
  "$type": integer

# $absent (07-conflicts.yml) -- a conflict changelog entry carries no version or manifest at all
manifest:
  "$absent": true
version:
  "$absent": true
```

## Interpolation

A `{{name}}` inside a request's `path`, any `query` value, any `body` value, or any `headers`
value is substituted with whatever an earlier step's `$capture` most recently bound to `name`,
within the same file. Interpolation only ever looks *inside strings* — it recurses through objects
and arrays looking for string leaves, and leaves every other scalar (a genuine number, boolean, or
`null` in a query or body value) untouched, because only a string can contain a template in the
first place.

**Referencing a name nothing captured raises, rather than sending the literal eight characters
`{{name}}` to the server.** This matters more than it might look: a request built from a
half-substituted template goes to a nonsense path or carries a nonsense value, and the resulting
404 or 401 points at *the server* as if something there were broken — when the actual mistake is a
scenario referencing a capture that was never made. Failing at the template, before the request
goes out, keeps the error where the mistake actually is. (This was a real bug, not a theoretical
one: before headers were interpolated at all, an unresolved header went out as the literal text
`Bearer {{device_b_token}}` and failed auth with a plain 401 — nothing about that response pointed
at interpolation as the cause.)

Headers are interpolated the same way path/query/body are. The one real case that needs it: a
scenario authenticating as a second, dynamically-enrolled device has no other way to name that
device's token, since it isn't known until `POST /v1/devices` returns it mid-run:

```yaml
# 04-nodes.yml
- name: begin shared.txt's third version AS DEVICE B, based on the first version -- stale
  request:
    method: POST
    path: "/v1/commit"
    headers:
      Authorization: Bearer {{device_b_token}}
    body: {...}
```

## Execution semantics a runner must reproduce

These are the parts of the format that live in *how* the corpus runs rather than in any one file's
shape, and they are exactly the parts most likely to bite an independent implementation, because
nothing about them is visible from reading a single scenario file in isolation.

**The corpus is one continuous session against one user, and files run in filename order.** Every
scenario file runs against the *same* device credential — one `SYNC_SERVER_URL` /
`SYNC_DEVICE_TOKEN` pair for the whole run — and files are not independent of each other: later
files rely on state earlier files left behind. `03-changes.yml`'s own description says so directly
("this user already has history from 02-commit.yml"), and `05-trash.yml`'s first three steps
restore tombstones that only exist because `04-nodes.yml`'s own last step put them there by
deleting a directory. `test/conformance_test.rb` calls Minitest's
`i_suck_and_my_tests_are_order_dependent!` for exactly this reason — its self-deprecating name is
itself a warning label: this suite is order-dependent **on purpose**, not a suite that forgot to
isolate its tests, and Minitest randomizes test method order by default, which would otherwise
silently break this. A from-scratch runner needs the equivalent: run every file, in filename
order (lexicographic sort of the two-digit-prefixed names is numeric order here), against one
freshly-authenticated session, start to finish, never in parallel and never in isolation.

**Capture bindings are scoped to one file, not to the whole corpus run.** Both the recorder and the
verifier create a *fresh* binding table per scenario file (`bin/conformance-record`'s own comment:
"fresh bindings per scenario file"; `test/conformance_test.rb` constructs a new
`Conformance::Matcher` inside the method that runs one file). A `$ref` can only resolve a name
captured earlier in the *same* file — never in an earlier file. This is worth stating precisely
because it would be easy to guess the opposite from "one continuous session": checking every
`$capture`/`$ref` name across all sixteen files today confirms every `$ref` is satisfied within its
own file, with zero cross-file references (`11-admin.yml` uses neither at all — its one value
worth asserting beyond a bare `$type`, the admin token, is a fixed literal both sides already
agree on, never a value only a live response can supply). What actually carries state from an
earlier file into a later one is **the server's own data**, not the runner's in-memory bindings:
`05-trash.yml`
restores the exact tombstoned node ids `04-nodes.yml` minted, but it does so with the same
structurally-obvious, human-chosen literal UUID (`00000000-0000-4000-8000-000000004001`, etc.) —
copied by the human who wrote the file, not threaded through any binding. A fresh implementation
should reset its capture table at the start of each file and rely on the live server, not on
carried-over bindings, for any file-to-file continuity.

**Some scenarios depend on state only an earlier file created**, beyond what's captured. Read a
scenario file's own `description` before assuming it's self-contained — several are explicit about
this (`03-changes.yml`'s baseline read is deliberately taken *without* asserting what earlier files
left in the changelog, specifically so the file works whichever earlier files ran before it, as
long as *some* did). Running scenario files out of order, or in isolation, is not a smaller version
of running the corpus — it's a different, unsupported thing to do, and running `05-trash.yml`
before `04-nodes.yml` (verified by deliberately doing it) turns a clean restore into a 404, on a
corpus where every individual file is otherwise correct.

**The corpus calls all 28 `/v1` routes, and never cared which part of a server answers them.** The
Ruby implementation split them — 26 drawn by the engine, and the two device-auth routes
(`POST /v1/devices`, `GET /v1/devices/whoami`) supplied by the host app that mounted it — and the
corpus ignored that boundary then as the binary has none now: it replays plain HTTP against one
base URL, and `01-enrolment.yml`, `04-nodes.yml`, `07-conflicts.yml`, and `08-locks.yml` all
exercise the two device routes directly, with their own pinned expectations, right alongside the
rest. (`11-admin.yml`'s `POST /v1/admin/libraries` is one of the 28 as well, gated by a distinct
SYNC_ADMIN_TOKEN rather than a device token.) A server being graded against this corpus needs
working, shape-compatible answers for all 28. How a from-scratch implementation chooses to
authenticate a device is its own business; what it returns from those two endpoints needs to
match what's recorded.

## Running it

### Against the reference server

The reference server is the Rust binary, and one command runs the whole corpus against it:

```sh
bin/conformance         # builds, boots on 127.0.0.1:3004 (SYNC_PORT), verifies, tears down
```

That is exactly what `.github/workflows/ci.yml`'s `conformance` job runs. It builds the binary,
creates a FRESH database and chunk directory in a temp directory, issues a fresh device, boots
`tinkerex-sync serve` with `STORAGE_BACKEND=local` and the admin token below, waits on `/up`, runs
the verifier, and fails on any skip or on zero runs. `CONFORMANCE_DATABASE_URL=postgres://…` points
it at an EMPTY Postgres database instead of the temp SQLite file.

**The fresh database is not a convenience.** For nine of the ten original scenario files it never
mattered whether the database was reset between runs — each run issues a brand-new user, so those
results are reproducible regardless of what else already lives in the database. **`11-admin.yml`
changed that**: it provisions a second user through `POST /v1/admin/libraries` with a fixed,
checked-in email (nothing in the conformance wire format lets a scenario file interpolate a per-run
value into a request body, so unlike the bootstrap device's email, this one has to be a literal both
the recording run and every later replay agree on), and its first successful step expects `201` —
which only the *first* run against a given database will ever get, `409` (`email_taken`) on every
run after. `14-tenancy.yml` provisions a second fixed email through the same door
(`tenant-b@tinkerex-sync.test`) for the same reason.

`SYNC_ADMIN_TOKEN` must be exactly `conformance-corpus-admin-token` — that literal is what
`11-admin.yml` sends as its admin credential, checked in for the same reason its fixture email is
(see that file's own `description`). It is a fixed test fixture, not a secret: it authenticates
nothing but this disposable, localhost-only server.

By hand, the same thing — issue the device under the DEFAULT name, which `08-locks.yml`'s
assertions expect:

```sh
cargo build -p tinkerex-sync && W="$(mktemp -d)"
export STORAGE_BACKEND=local SECRET_KEY_BASE=dev SYNC_ADMIN_TOKEN=conformance-corpus-admin-token \
  SQLITE_DATABASE="$W/sync.sqlite3" CHUNK_LOCAL_DIR="$W/chunks"
target/debug/tinkerex-sync migrate                                # prints Created
target/debug/tinkerex-sync device issue --email you@example.com   # prints a device token, once
target/debug/tinkerex-sync serve --bind 127.0.0.1 --port 3003 &
```

Then, from the repository root:

```sh
SYNC_SERVER_URL=http://127.0.0.1:3003 SYNC_DEVICE_TOKEN=<token printed above> \
  bundle exec ruby -Itest test/conformance_test.rb
```

Verified output, run against a freshly-issued device on a freshly-created database — reported by
the Ruby host and the Rust binary alike on 2026-09-30, and by the binary alone, with the Ruby gone,
on 2026-10-14 (the eleven-file corpus of 2026-08-24 reported `13 runs, 163 assertions`):

```
18 runs, 284 assertions, 0 failures, 0 errors, 0 skips
```

(Sixteen of those runs are one per scenario file; the other two are fixed, server-independent
checks — "the corpus has at least one scenario file," and "every route the binary prints is
exercised by at least one scenario," described further under "What this corpus does not cover.")

`test/conformance_test.rb` is an ordinary Minitest file, so it also runs as part of plain `bundle
exec rake test` — but with no `SYNC_SERVER_URL` set, every per-scenario test **skips** rather than
failing or erroring, on purpose (this corpus's whole point is exercising a real running server, so
there is no in-process fake standing in for one when none is configured). A skip and a pass both
report "not red" to Minitest, so nothing *inside* that suite can tell you whether it actually ran —
`bin/conformance` handles this by parsing the run's own summary line and failing outright on any
nonzero skip count, or on zero runs. Take the same precaution in your own CI: a clean exit with a
skipped conformance suite is a false green, not a slow one.

### Against your own server

Point the same two environment variables at your own implementation — nothing about running the
corpus is Ruby-specific:

```sh
SYNC_SERVER_URL=http://127.0.0.1:<your port> SYNC_DEVICE_TOKEN=<a token your server issued> \
  <your runner> conformance/scenarios/*.yml
```

Your server needs to be reachable over plain HTTP, needs some way to mint a bearer device token a
caller presents as `Authorization: Bearer <token>`, and needs to answer all 28 routes the corpus
actually calls (see "Execution semantics" above) in a way that satisfies each step's recorded
`expect:`. It does not need to reuse this repository's specific device-issuance mechanism
(`tinkerex-sync device issue`, or `POST /v1/devices` from an already-authenticated device) — only
to produce a token the corpus can use the same way. One route needs a SECOND, DIFFERENT credential:
`11-admin.yml`'s `POST /v1/admin/libraries` steps authenticate with a fixed literal
(`conformance-corpus-admin-token`, checked in for the reason that file's own `description`
explains), never a device token — your server needs to be configurable to accept that exact value
as its admin credential, or the recording could not have been reproduced against it in the first
place.

**The user behind that token must be genuinely fresh — zero prior history — or the very first
assertion in the corpus fails for a reason that has nothing to do with your server.**
`01-enrolment.yml`'s first step pins `head_seq: 0` as a bare literal, which is only true of a user
that has never made a mutation. This is why `bin/conformance`, which runs this corpus against the
reference server, mints a brand-new user, with a unique email, on every single run rather than
reusing one — do the same against your own implementation: a fresh user/device pair per run, not a
long-lived test account you replay the corpus against repeatedly.

## Adding or re-recording a scenario

### Writing a new scenario

Write the file by hand: `name`, `description`, and one `request:` per step, fully specified.
Leave every step's `expect:` as an empty object, `expect: {}` — this is the recorder's own signal
for "not yet recorded," and it means a brand-new file is **not** yet valid against
`conformance/schema.json` (which requires `status` inside `expect`) until it has been through the
recorder at least once. That's expected: `bin/conformance-record` does not validate against the
schema at all (it only checks for a top-level `steps:` array), so authoring order is write the
requests, record, *then* the file becomes schema-valid.

### Recording

```sh
SYNC_SERVER_URL=http://127.0.0.1:3003 SYNC_DEVICE_TOKEN=<a fresh device's token> \
  bin/conformance-record conformance/scenarios/your-new-file.yml
```

Every step whose `expect:` is empty gets filled in from the real response, printed as `[rec]`.
**Every step whose `expect:` already holds something is protected** — it prints `[skip]` and is
never overwritten without `--force` — but its request is still sent live regardless, every run,
for two reasons: a later step may depend on the side effect an earlier one causes (a node has to
exist before a later step can move it), and the already-recorded expectation is replayed against
the live response to reconfirm it still holds *and* to re-seed any `$capture` bindings a later,
still-empty step's `{{name}}` needs. Concretely: if you add one new step to the end of an existing,
already-recorded file, running the recorder still replays every earlier step against a live
server — which means you need a device/user whose state is compatible with the *whole* file from
the start, not just the new step. In practice that means recording against a freshly-issued
device and running the full corpus in order up to and including your new file, the same way it
runs in CI.

A value the recorder decides is volatile — its *key name* ends in `id`, `_id`, `at`, `_at`,
`token`, or `_token` — is written as `{"$type": "..."}` rather than as the literal it happened to
be. Every one of these is printed again at the end of the run:

```
$type written (1):
  mkdir READMEDemo at the root > body.node_id -> $type: string
```

### Reviewing what got written

**This is not optional. It's the review step that makes a recorded corpus trustworthy rather than
merely convenient.** The recorder's volatility rule is deliberately blunt — it looks at a field's
*name*, never its actual value or how it got there — and it is wrong in both directions in ways
this repository's own corpus demonstrates:

- **Too loose.** `commit_id` and `node_id` are client-chosen UUIDs in this API (the values a
  scenario author already picked and put in the *request*), not server-assigned — but their names
  end in `_id`, so the recorder writes `{"$type": "string"}` for them by default. The corpus's own
  authors tightened these into the literal value already known from the request (e.g.
  `02-commit.yml`'s `commit_id: ed85b9c8-d89b-4385-9fc6-33b28c08a9e3`, echoed back and pinned
  exactly, not merely type-checked) — a strictly stronger assertion that would catch a server
  echoing back the *wrong* id, which `$type: string` cannot.
- **Too tight, the opposite direction.** `seq` doesn't end in `id`/`at`/`token`, so the recorder
  writes it as a bare literal integer by default — and on a truly fresh, first-in-line user that
  literal happens to be correct (a fresh user's first mutation really is seq 1). But it is only
  *coincidentally* correct: rerun the same request against a user with different prior history, or
  reorder the corpus, and the literal breaks for a reason that has nothing to do with the server
  being wrong. Check the real corpus and this holds exactly as stated — no scenario file pins `seq`
  as a bare literal anywhere; every real occurrence is `$type: integer`, `$capture`, or `$ref`. A
  human loosened every one of them by hand.

Both examples above were reproduced directly while writing this document, not merely inferred from
reading the source — including the second one, `seq`, recording as a plain literal on a freshly
recorded scenario before being manually caught and loosened here, which is exactly the failure
mode this review step exists to catch before it reaches the committed corpus.

So: after recording, look at every `$type` the run reported and ask whether it should instead be a
literal (the value is actually deterministic — usually because it's client-chosen), a `$capture`/
`$ref` pair (the value is genuinely new but something later needs to check against it), or is
correctly a `$type` (genuinely volatile and nothing downstream cares about the specific value).
Separately, look at every literal the recorder wrote and ask the mirror question — is this value
actually guaranteed to repeat, or did it just happen to this time?

### `--force`

```sh
bin/conformance-record --force conformance/scenarios/your-file.yml
```

`--force` discards **every** step's recorded `expect:` — including any hand-added `$capture`,
`$ref`, or hand-tightened/loosened literal — and replaces it wholesale with a fresh mechanical
guess from the live response, as if the file had never been recorded at all. It is a blunt
"start over" escape hatch, not a per-step scalpel: there is no way to force-record one step while
leaving a sibling step's hand curation alone.

**Two caveats, both verified directly, not merely read off the code's own comments:**

1. **Any human curation on disk is lost, in both directions — tightening and loosening alike.**
   Force-recording a copy of `02-commit.yml` against a fresh device reproduced exactly what the
   source comments describe. (Trimmed to the three fields that actually changed — `...` marks an
   elision, not literal YAML, and the chunk hash is truncated for width; the real keys are the full
   64-character hex hash from the checked-in file.)

   ```yaml
   # before (hand-curated, checked in)
   commit_id: ed85b9c8-d89b-4385-9fc6-33b28c08a9e3
   ...
   put_urls:
     cdb31e4c...29:
       "$capture": drawing_put_url
   ...
   seq:
     "$type": integer

   # after --force, against a fresh user
   commit_id:
     "$type": string
   ...
   put_urls:
     cdb31e4c...29: http://127.0.0.1:3003/v1/chunks/blob/17/cdb31e4c...29?exp=...&sig=...
   ...
   seq: 1
   ```

   The client-chosen `commit_id` reverts from a pinned literal back to a loose `$type: string`
   guess. The captured `put_urls` entry reverts from `$capture` to a raw, one-time presigned URL —
   which will **not** match on the next run (a fresh presigned URL has a different signature and
   expiry every time) and, worse, leaves nothing bound for the very next step's own
   `{{drawing_put_url}}` to interpolate. And `seq`'s own hand-loosened `$type: integer` reverts to a
   bare literal that only happens to be right against a freshly-issued device. All three have to be
   re-curated by hand after a forced re-record, exactly as after the very first recording ever
   made — `--force` does not try to be cleverer than that about a step's own expectation.

   One thing `--force` gets right on its own, also verified directly: **`bind_captures!` (not the
   validating `match!`) walks each step's *old* expectation against the *new* live response before
   overwriting it, purely to keep already-bound `$capture` names usable for interpolating the
   *rest of the same run* — never raising, even when the old shape no longer matches at all.**
   This is why a multi-step chain inside one file (begin a commit, capture a presigned PUT URL,
   `PUT` to `{{that url}}`) still completes correctly under `--force`, even though the `$capture`
   itself does not survive on disk afterward. Confirmed by literally running
   `bin/conformance-record --force` against a copy of `02-commit.yml`: it completed cleanly,
   uploading through the newly re-minted presigned URL rather than crashing on an unresolved
   `{{drawing_put_url}}` — which is exactly the bug this mechanism was added to fix (an earlier
   version of the recorder discarded the old expectation without ever reading it, and the very next
   step's interpolation raised "no earlier `$capture` bound this name").

2. **A `$ref` is inert under `--force` — it is neither re-validated nor turned into a new binding.**
   A `$ref` only ever checks a value against something captured earlier; forcing a walk through the
   *old* `$ref` the way `match!` would have costs nothing to skip, and skipping it is what keeps
   `--force` from becoming a second, unwanted validation pass over exactly the drift it exists to
   accept.

A re-record that changes nothing writes nothing — the recorder rewrites a scenario file
deterministically (sorted keys, for whatever content it builds itself) and produces byte-identical
output when there is genuinely nothing new to say. Verified directly: force-recording
`01-enrolment.yml` (a fresh device, no `$capture` chain to lose) reproduced the checked-in file
byte for byte.

## What this corpus does not cover

Be skeptical of a passing corpus in the specific way its own design invites: **a pass here proves
wire conformance for the exchanges this corpus actually recorded — not general correctness, and
not exhaustive endpoint coverage.**

- **The coverage check proves reachability, not thoroughness.** `test/conformance_test.rb` reads
  `conformance/routes.txt` — what `tinkerex-sync routes` prints, held to the binary byte for byte
  by a Rust test (`crates/tinkerex-sync/tests/routes.rs`) — refuses it if it is empty, and asserts
  every listed route is hit by at least one scenario step somewhere in the corpus. Today all 28
  `/v1` routes are; `COVERAGE_EXCEPTIONS`, the named-and-reasoned escape hatch for a route that
  can't reasonably be exercised, holds the other two, `GET /up` (the readiness probe) and
  `GET /cable` (a WebSocket, which `crates/tinkerex-sync/tests/cable.rs` drives instead). Until the
  Ruby left, the check drew the Ruby engine's own 26 routes instead. But
  "exercised by at least one step" says nothing about how many of an endpoint's status codes,
  branches, or edge cases are pinned. `POST /v1/commit`'s missing-chunk path, dedup path, and
  refused-finalize path are each their own separate step in `02-commit.yml` because someone chose
  to record each one — the coverage check would be satisfied by far less.
- **A recorded response is only as good as the review it got.** The whole design leans on a human
  reading each recorded expectation and judging it correct (see "Why this corpus exists"). A
  reviewer who rubber-stamps a `$type` guess without asking whether it should have been a literal
  gets a corpus that passes without actually pinning what it looks like it pins — see the `seq`
  example above.
- **Concurrency, timing, and TTL-based behavior are out of scope by construction.** Every scenario
  is a strictly ordered sequence of single HTTP calls; nothing here exercises two requests racing
  each other, and nothing waits out a real TTL (`08-locks.yml` proves a lock is *held*, never that
  it *expires* — that would need the corpus to sleep for real minutes, which nothing here does).
- **The corpus is silent about anything not reachable through the v1 HTTP API** — background jobs,
  chunk garbage collection, retention policy, and anything else that isn't a request/response pair
  a client could make.
- **This document, and the corpus, deliberately says nothing about *why* an endpoint behaves the way
  it's recorded to behave.** That belongs to `docs/sync-protocol.md`. A recorded 409 tells a Rust
  implementation *that* the server refuses a given request; it does not explain the reasoning,
  which is the normative document's job, not this corpus's.

To reproduce the route count yourself rather than trust this document's number:

```sh
cargo run -q -p tinkerex-sync -- routes | grep -c ' /v1/'   # 28 (30 lines in all: /up and /cable too)
cargo run -q -p tinkerex-sync -- routes | diff - conformance/routes.txt && echo "routes.txt is current"
```
