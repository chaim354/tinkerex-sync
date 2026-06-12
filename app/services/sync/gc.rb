module Sync
  # Chunk garbage collection.
  #
  # Refcounts track how many live versions reference a chunk. Deleting a *node* only
  # tombstones it — versions (and their chunks) are retained so restore stays
  # possible. Chunks are freed only when a *version* is pruned by a retention policy,
  # which decrements refcounts; chunks that reach 0 are swept here.
  #
  # v1 keeps all history (no aggressive pruning) so restore always works. This
  # exposes the mechanism: prune_version! for the future retention job, and
  # sweep_orphans! for the periodic cleaner (also catches uploaded-but-never-finalized
  # chunks, which are never inserted, and finalized-then-superseded ones once pruned).
  class Gc
    # Decrement refcounts for a version's chunks and delete the version. Call from a
    # retention policy (keep last N / daily-for-30d) — NOT in the normal write path.
    def self.prune_version!(user, version)
      ApplicationRecord.transaction do
        hashes = ManifestChunk
                 .where(user_id: user.id, manifest_id: version.manifest_id)
                 .distinct.pluck(:chunk_hash)
        user.chunks.where(chunk_hash: hashes).where("refcount > 0")
            .update_all("refcount = refcount - 1") if hashes.any?
        version.destroy!
      end
    end

    # Prune changelog history at or below `keep_after`, leaving the tree + versions
    # intact (the snapshot still reflects current state). A device whose cursor falls
    # below the new floor must full-resync from the snapshot — the client detects this
    # via the `oldest_seq` the changes endpoint now reports. Call from a retention policy,
    # NOT in the write path. Returns the count pruned.
    def self.prune_changelog!(user, keep_after:)
      user.changelog_entries.where("seq <= ?", keep_after).delete_all
    end

    # Delete chunk metadata + storage objects for chunks at refcount 0 past a grace
    # period. Storage deletion is best-effort.
    def self.sweep_orphans!(user, grace: 1.hour)
      cutoff = grace.ago
      user.chunks.where(refcount: ..0).where("updated_at < ?", cutoff).find_each do |chunk|
        # Storage::ChunkStore could expose delete(user_id, hash); omitted here as the
        # presign-only interface doesn't delete. Wire a delete() when adding S3 admin.
        chunk.destroy
      end
    end
  end
end
