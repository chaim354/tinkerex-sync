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
