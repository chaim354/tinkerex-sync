module Sync
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
    ManifestChunk
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
