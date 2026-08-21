# LIVES IN lib/, NOT app/services/sync.rb, AND THAT IS A ZEITWERK CONSTRAINT, NOT A STYLE CHOICE.
# `isolate_namespace Sync` (engine.rb) necessarily pre-defines the bare `Sync` module the moment
# this gem is required -- `isolate_namespace` takes an already-resolved constant as its argument,
# so `module Sync; class Engine < ::Rails::Engine; isolate_namespace Sync; end; end` DEFINES `Sync`
# on its first line, at Bundler.require time, before any Zeitwerk loader (the app's or this
# engine's own) has been constructed, let alone run `setup`.
#
# Zeitwerk's "explicit namespace" handling -- the mechanism that would let a file like
# `app/services/sync.rb` add methods to the SAME module a directory `app/models/sync/` nests
# under -- only fires for a constant Zeitwerk itself is about to autoload. A constant that is
# ALREADY a real object when Zeitwerk scans for it is treated as satisfied: no autoload is set for
# ANY file matching that exact root name, silently, eager_load included, with no error or
# warning. VERIFIED with a bare Zeitwerk::Loader (no Rails): `module Sync; end` followed by
# `push_dir` + `setup` (then `eager_load`) never requires a same-named `sync.rb` at that root, and
# a method defined in it is simply never callable. This is what broke boot the first time this file
# moved from the host's `app/services/sync.rb` into `app/services/` here unchanged: the diagnosis
# ("the engine's own Zeitwerk loader will own it") assumed Zeitwerk could re-associate an
# already-open module with a file, and it cannot.
#
# The fix is the same one `table_name_prefix` (engine.rb) already uses for the identical problem:
# skip autoloading entirely and reopen `Sync` from plain, eagerly-`require`d code (see
# lib/tinkerex_sync.rb's `require "tinkerex_sync/sync_module"`). This is also the standard shape
# for isolated-engine, module-level config methods elsewhere (Devise's lib/devise.rb, not
# app/models/devise.rb) -- not a workaround invented for this file.
module Sync
  # SEAM for Stage 3b, not a settled fact (Stage 3a plan, Task 3). Until the sync engine is
  # genuinely separable there is no engine OBJECT to ask "are you mounted", so this predicate
  # answers the question the only honest way available today: which LIBRARY_BACKEND is this
  # deployment running. `lib/postgres_pooler_check.rb`'s boot guard is the one caller
  # (`PostgresPoolerCheck.probe?`'s `engine_present:` default) — it exists solely to protect
  # `User#next_seq!`'s row lock, which only a chunk deployment ever calls, so a share or s3
  # deployment must never be refused a boot behind a statement-mode pooler over a rule that
  # cannot apply to it.
  #
  # NOT `LIBRARY_BACKEND == "chunk"` INLINED AT THE CALL SITE, AND NOT
  # `FileLayer.current.capabilities.syncable?` EITHER, though both read the same three backends
  # today and would agree with this method on all of them. §14a's whole argument is that such
  # agreement is a coincidence of having exactly three backends, not an identity — `scannable` is
  # not `!syncable?`, `port_writable` is not `scannable`, and encoding one of those coincidences
  # once already (`is_a?(Share)`) is how it silently went wrong the moment a second backend
  # arrived. `syncable?` in particular asks a DIFFERENT question that only happens to share
  # today's answer: whether the maker layer's file tree arrives via the changelog, not whether a
  # changelog and its seq allocator exist AT ALL. Spelling this method as a reference to that one
  # would silently disable a lock-corruption guard the day a backend answers `syncable? == false`
  # while still running the engine for some other reason — exactly the kind of assumption §14a
  # keeps finding broken in practice, not a hypothetical.
  #
  # A NAMED, OWNED predicate is what lets Stage 3b change ONLY this method's body — to something
  # like "is there a mounted Sync::Engine railtie", or a flag the engine sets when present — with
  # no caller anywhere needing to change. Reuse this name rather than re-deriving the question
  # from LIBRARY_BACKEND a second time somewhere else.
  #
  # `env:` is a kwarg default rather than a captured constant or ivar — same shape as
  # `PostgresPoolerCheck.probe?`'s own `env:`, for the same reason: ENV is re-read on every call,
  # so a value injected by one test cannot leak into the next.
  # THE NAME DESCRIBES WHAT THIS WILL MEAN, NOT WHAT IT MEASURES TODAY, and a final review was right
  # to call that out. In this monorepo the Sync module is loaded unconditionally on every backend --
  # nothing about the engine's PRESENCE in the process varies. What varies is whether this deployment
  # USES it, which is what LIBRARY_BACKEND actually answers. The name is deliberate anyway: it is the
  # question 3b's caller wants to ask, and 3b replaces this body with a real engine object without
  # touching a single call site. Until then, read the body, not the name, before adding a caller --
  # there is exactly one today (PostgresPoolerCheck.probe?).
  def self.engine_present?(env: ENV)
    env.fetch("LIBRARY_BACKEND", "chunk") == "chunk"
  end

  # STAGE 3b TASK 9 — THE HOST-CONFIGURABLE HALF OF THE ENGINE'S OWN CAPABILITY GATE. CLAUDE.md
  # §14j named two host dependencies left inside the engine after Phase B: `Sync::V1::BaseController`
  # `include ::LibraryCapabilities` and `Sync::V1::ShareController` reading
  # `::FileLayer.current.capabilities.versioned?` directly — both host constants, neither
  # autoloadable in a bare mount with no host application present. `Sync::V1::CapabilityGate`
  # (app/controllers/concerns/sync/v1/capability_gate.rb) is the engine's own `require_capability!`,
  # replacing that direct `include`; it and `Sync::V1::ShareController` both ask the two questions
  # below instead of naming `FileLayer` or `LibraryCapabilities` themselves.
  #
  # THE STANDALONE DEFAULT IS "EVERY CAPABILITY IS AVAILABLE," UNCONDITIONALLY — NOT A
  # PLACEHOLDER PENDING CONFIGURATION, THE CORRECT PERMANENT ANSWER FOR A BARE SYNC SERVER.
  # CLAUDE.md §2: this engine IS the sync engine. It has a changelog, chunks, devices and
  # versions by construction, so `syncable`/`versioned`/anything else this gate is ever asked
  # about is true for as long as the process exists at all. The capability QUESTION exists only
  # because a HOST can configure a share- or s3-backed library that has none of that (§14a) — a
  # fact about the host's FileLayer port, not about the engine. So the permissive default is the
  # engine correctly describing itself with nothing else attached, never "fail open until someone
  # gets around to configuring it."
  #
  # TWO CONFIGURABLES, NOT ONE — matching `require_capability!`'s two jobs: whether the request
  # may proceed, and what to say if it may not. The host wires both together, once, in
  # `config/initializers/sync_capabilities.rb`, to `FileLayer.current.capabilities` and
  # `LibraryCapabilities::CAPABILITY_ABSENT` — so its 501 bodies stay byte-identical to what direct
  # inclusion produced. Collapsing them into one combined callable would work for THIS host, which
  # always has both answers ready together, but would force every future host to rebuild the
  # availability logic just to reword a sentence.
  #
  # NAMED CONSTANTS FOR THE DEFAULTS, NOT ONLY `mattr_accessor`'s OWN `default:` KWARG — so a test
  # (or a future caller) can restore the exact standalone answer after temporarily overriding it,
  # the same "you broke it, you put it back" contract `Sync::Hooks.reset!` states for its own
  # subscriber list. Once a host initializer runs `Sync.capability_check = ...`, the ORIGINAL
  # default the accessor was built with is no longer reachable through the accessor itself — Ruby
  # does not retain it once the class variable is reassigned — so recovering "what does a bare
  # mount answer" would otherwise mean re-deriving the lambda from scratch, which drifts the
  # moment one copy changes and not the other. A named constant sidesteps that.
  #
  # `instance_accessor: false` ON BOTH — nothing includes the bare `Sync` module as a mixin, so
  # the instance-level reader/writer `mattr_accessor` would otherwise define are surface with no
  # caller, ever.
  #
  # THE HOST INITIALIZER MUST ASSIGN THESE FROM INSIDE `Rails.application.config.after_initialize`
  # (same as `config/initializers/sync_hooks.rb` and `postgres_pooler_check.rb`, for the identical
  # reason stated in both: `Sync` and the host constants these lambdas eventually touch are not
  # reliably autoloadable while initializers are still running). But the sharper reason belongs to
  # the two methods' CALLERS, not to this file — see `Sync::V1::CapabilityGate`'s own header for why
  # `capability_available?`/`capability_unavailable_message` must be invoked from inside a
  # `before_action` block, at request time, and never at `require_capability!`'s own call time.
  DEFAULT_CAPABILITY_CHECK = ->(_capability) { true }
  DEFAULT_CAPABILITY_MESSAGE = ->(capability) {
    "this deployment does not support the #{capability} capability."
  }

  mattr_accessor :capability_check, instance_accessor: false, default: DEFAULT_CAPABILITY_CHECK
  mattr_accessor :capability_message, instance_accessor: false, default: DEFAULT_CAPABILITY_MESSAGE

  # Is `capability` available RIGHT NOW, in THIS deployment? The only question
  # `Sync::V1::CapabilityGate#require_capability!` asks before rendering 501.
  def self.capability_available?(capability) = capability_check.call(capability)

  # Why not, in the operator's terms. Meaningful only once #capability_available? has already
  # answered false — a caller must not treat a non-nil message here as itself meaning
  # "unavailable."
  def self.capability_unavailable_message(capability) = capability_message.call(capability)

  # Shared bulk-loading helper for the read serializers (G11 scale validation).
  #
  # Manifests are stored as `manifest_chunks` rows keyed by the string `manifest_id`
  # (there is no AR association on that key). Both the snapshot (`Sync::Tree`) and the
  # delta (`Sync::Changes`) need, for a *set* of manifest ids, the ordered chunk list of
  # each — and they must not issue one query per manifest (the original N+1). This loads
  # every chunk for the given ids in ONE query, then groups + orders in memory.
  #
  # Returns `{ manifest_id => [{ hash:, offset:, length: }, ...], ... }` with each list
  # ordered by chunk `seq`. Portable: a single `WHERE manifest_id IN (...)` ordered by
  # (manifest_id, seq) — no PG-only SQL, correct on SQLite + Postgres.
  def self.load_manifests(user, manifest_ids)
    ids = Array(manifest_ids).uniq
    return {} if ids.empty?

    grouped = Hash.new { |h, k| h[k] = [] }
    Sync::ManifestChunk
      .where(user_id: user.id, manifest_id: ids)
      .order(:manifest_id, :seq)
      .pluck(:manifest_id, :chunk_hash, :offset, :length)
      .each do |mid, hash, offset, length|
        grouped[mid] << { hash: hash, offset: offset, length: length }
      end
    grouped
  end

  # `version_id => size` for a SET of version ids, in ONE query.
  #
  # WHY THIS EXISTS AT ALL: `Node#current_version` is a `find_by`, not an association (there is no
  # AR association on the string `version_id` key), so `includes` cannot reach it and every bulk
  # serializer that wants a node's size must collapse the per-row lookup by hand. Three sites had
  # already hand-rolled this exact query before it had a name (`FileLayer::Chunk#stat_all`,
  # `Chunk#trashed`, and `Sync::Tree`'s `index_by` variant); `V1::TrashController#index` was the
  # one that had NOT, and paid 4 + N queries over a list `Chunk#trashed`'s own comment describes as
  # "unbounded (it is every file the user ever deleted)". Measured on the real endpoint before the
  # fix: N=1 → 5, N=5 → 9, N=25 → 29; after → a constant 5.
  #
  # THE `user.` SCOPE IS NOT DECORATION, AND IT IS LOAD-BEARING TWICE. It is §8's ordinary
  # `user_id` scoping — a `version_id` is not tenant-salted, so an unscoped read can return another
  # tenant's row rather than none. It is ALSO the index: `versions` carries
  # `(user_id, version_id)` and `(user_id, node_id, id)` and NOTHING on `version_id` alone, so
  # `Version.where(version_id: ids)` plans as `SCAN versions` (verified via EXPLAIN QUERY PLAN)
  # while the scoped form is a `SEARCH … USING INDEX index_versions_on_user_id_and_version_id`.
  # Dropping the scope is both a tenancy hole and a full scan of the largest sync table.
  #
  # A MISSING VERSION IS AN ABSENT KEY, NOT A RAISE — the same rule as the port's `stat_all`
  # (§14a). The caller holds a LIST and a row that vanished mid-page must not take the page down;
  # `sizes[id]` then answers nil, which is byte-identical to what `n.current_version&.size` said.
  #
  # `return {} if ids.empty?` MIRRORS `load_manifests` ABOVE AND SAVES NO QUERY — do not document
  # it as one. Probed on rack/rails as shipped here: `user.versions.where(version_id: []).pluck`
  # issues **zero** queries, because Rails short-circuits an empty IN-list before it reaches the
  # adapter. So a trash of directories costs the same with the line and without it, and no
  # query-count guard can ever go red for deleting it. It stays for symmetry with its neighbour and
  # because a plain `{}` is a cheaper answer than building the relation; that is its whole claim.
  def self.load_version_sizes(user, version_ids)
    ids = Array(version_ids).compact.uniq
    return {} if ids.empty?

    user.versions.where(version_id: ids).pluck(:version_id, :size).to_h
  end
end
