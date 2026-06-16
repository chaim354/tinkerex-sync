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
  # sweep_orphans! for the periodic cleaner (frees finalized-then-superseded chunks once
  # pruned to refcount 0). NOTE: sweep_orphans! walks DB rows, so it does NOT reclaim
  # chunk bytes from a commit that uploaded but never finalized — those have no `chunks`
  # row at all. That storage-side leak is handled by Sync::ChunkReaper (G4).
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

    # Apply a retention policy across a user's whole library, then sweep freed chunks.
    #
    # For each node: compute the policy's keep-set (which ALWAYS includes the node's
    # current_version + any pinned version), then prune_version! every version NOT in it.
    # Pruning decrements the version's chunks' refcounts; sweep_orphans! then frees any
    # chunk that reached refcount 0 past the grace window (DB row + storage object).
    #
    # Self-host defaults to keep_all (nothing is pruned). Pass a Tiered policy (or set
    # RETENTION_POLICY=tiered) for managed thinning. Returns the number of versions pruned.
    def self.apply_retention!(user, policy: RetentionPolicy.default, grace: 1.hour)
      pruned = 0
      node_ids = user.versions.distinct.pluck(:node_id)
      node_ids.each do |node_id|
        node = user.nodes.find_by(node_id:)
        versions = user.versions.where(node_id:).to_a
        keep = policy.keep_set(versions, current_version_id: node&.current_version_id)
        versions.each do |v|
          next if keep.include?(v.version_id)
          prune_version!(user, v)
          pruned += 1
        end
      end
      sweep_orphans!(user, grace:)
      pruned
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
    # period. Never frees a still-referenced or freshly-zeroed chunk.
    #
    # Order matters for failure-safety: destroy the DB row FIRST, then delete the
    # storage object. A storage outage therefore can't corrupt refcount state — at
    # worst it orphans bytes in the object store, which a later sweep (or manual
    # reconcile) re-deletes harmlessly (delete is idempotent). The row is the source of
    # truth for "is this chunk live"; we never leave a row pointing at deleted bytes.
    def self.sweep_orphans!(user, grace: 1.hour)
      grace = grace.seconds if grace.is_a?(Numeric)
      cutoff = grace.ago
      store = Storage::ChunkStore.current
      # `<=` so grace: 0 means "sweep immediately" (a chunk zeroed at `now` is collectable)
      # rather than depending on real microseconds elapsing between the refcount touch and
      # this query — which made grace-0 sweeps non-deterministic under a frozen test clock.
      user.chunks.where(refcount: ..0).where("updated_at <= ?", cutoff).find_each do |chunk|
        hash = chunk.chunk_hash
        chunk.destroy
        begin
          store.delete(user.id, hash)
        rescue => e
          # Best-effort: the row is already gone, so refcount accounting stays correct.
          # Log and continue; the orphaned object is reclaimed on a later sweep.
          Rails.logger.warn("Sync::Gc.sweep_orphans! storage delete failed for " \
                            "chunks/#{user.id}/#{hash}: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
