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
end
