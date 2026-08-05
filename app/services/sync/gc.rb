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
    #
    # Returns true if THIS call pruned the version, false if someone else already had.
    #
    # CLAIM-THEN-DECREMENT, NOT DECREMENT-THEN-DESTROY, and the order is the whole overlap
    # story. `apply_retention!` loads its version lists OUTSIDE any lock, so two overlapping
    # RetentionJobs (nothing declared `limits_concurrency` before 2026-08-05, and even with it
    # an operator can still run two by hand) can both decide to prune the SAME version. The old
    # order let both decrement — the `WHERE refcount > 0` guard prevents a NEGATIVE refcount,
    # which is not the bug; the bug is a chunk SHARED with a surviving version being decremented
    # twice for one removal, reaching 0 while still live, and then being freed by
    # sweep_orphans!. Deleting the version row first makes the row itself the claim: `delete_all`
    # reports how many rows it actually removed, so exactly one caller sees 1 and decrements.
    def self.prune_version!(user, version)
      ApplicationRecord.transaction do
        # Serialize against the seq-writers (Sync::Commit/Restore/Conflicts all take the user-row
        # lock first). Without this, a concurrent Restore/split that bumps THIS version's chunks'
        # refcounts can interleave with our decrement-then-destroy: the restore reuses the manifest
        # while we're zeroing its refcounts, and sweep_orphans! could then free a chunk a live
        # version references. Taking the same FOR UPDATE lock makes prune and the bumpers mutually
        # exclusive per user.
        user.lock!
        # Version has no callbacks and no `dependent:` associations, so delete_all is
        # behaviourally identical to the destroy! this replaces — it just also reports the count.
        claimed = user.versions.where(version_id: version.version_id).delete_all == 1
        next false unless claimed

        hashes = ManifestChunk
                 .where(user_id: user.id, manifest_id: version.manifest_id)
                 .distinct.pluck(:chunk_hash)
        touch_refcounts!(user.chunks.where(chunk_hash: hashes).where("refcount > 0"), by: -1) if hashes.any?
        true
      end
    end

    # THE ONE PLACE A REFCOUNT MOVES WITHOUT `updated_at` MOVING WITH IT — which is to say,
    # nowhere. Every refcount mutation in this codebase is a raw `update_all` (bulk, by hash, no
    # model instantiation), and `update_all` does NOT maintain timestamps. That is fine for the
    # count itself and was silently fatal for sweep_orphans!, whose grace window filters on
    # `updated_at`: with the column only ever written at insert_all time, the filter tested the
    # chunk's CREATION age rather than its ZEROING age, so for any chunk older than the grace
    # window — i.e. every real chunk — the protection the sweep's own contract promises did not
    # exist at all. Route every refcount write through here so the two cannot drift apart again.
    #
    # BOTH VALUES ARE BOUND, none interpolated. `by:` is an Integer delta (+1 / -1), not a SQL
    # fragment — the first draft interpolated a "+ 1"/"- 1" string, which Brakeman's SQL check
    # flagged (weak confidence) and which was worth fixing rather than ignoring: an operand is
    # data, and writing it as data costs nothing and leaves no judgement call for the next reader.
    # Array form so both adapters quote the timestamp correctly.
    def self.touch_refcounts!(relation, by:, now: Time.current)
      relation.update_all([ "refcount = refcount + ?, updated_at = ?", by, now ])
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
      # Versions still referenced by an UNRESOLVED conflict or a LIVE share link must never be
      # pruned, regardless of the retention tier math:
      #   - an open conflict's incoming/base version: Sync::Conflicts.keep/split re-reads it to
      #     resolve — pruning it makes resolution raise (500) and loses the edit's chunks,
      #     breaking the "never lose an edit" invariant.
      #   - a live share link's frozen version: presigned GETs against its manifest would dangle.
      referenced = referenced_version_ids(user)
      node_ids = user.versions.distinct.pluck(:node_id)
      node_ids.each do |node_id|
        node = user.nodes.find_by(node_id:)
        versions = user.versions.where(node_id:).to_a
        keep = policy.keep_set(versions, current_version_id: node&.current_version_id)
        versions.each do |v|
          next if keep.include?(v.version_id) || referenced.include?(v.version_id)
          # Counts CLAIMS, not attempts: under an overlapping pass the loser prunes nothing and
          # must not report that it did (see prune_version!).
          pruned += 1 if prune_version!(user, v)
        end
      end
      sweep_orphans!(user, grace:)
      pruned
    end

    # Every version_id a retention pass must protect beyond the policy keep-set: both sides of
    # each unresolved conflict (incoming + base/current) and every live share link's version.
    def self.referenced_version_ids(user)
      ids = Set.new
      user.conflicts.unresolved.pluck(:incoming_version_id, :current_version_id).each do |inc, cur|
        ids << inc if inc.present?
        ids << cur if cur.present?
      end
      user.share_links.each { |sl| ids << sl.version_id if sl.live? && sl.version_id.present? }
      ids
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
    #
    # COMPARE-AND-DELETE, because this sweep deliberately takes NO user lock (unlike
    # prune_version!) and therefore races every refcount BUMPER. The batch this iterates is a
    # snapshot: between the query and the delete, a concurrent Sync::Commit#finalize can dedup
    # against a still-present row and take it 0 → 1, uploading NOTHING because the row says the
    # bytes are already there. Deleting on the strength of the snapshot then leaves a live
    # version pointing at a chunk with no row and no bytes — silent, permanent data loss, and
    # finalize's own verify closes only the orderings where the row is already gone by the time
    # it looks. Re-asserting `refcount: ..0` inside the DELETE makes the database adjudicate:
    # the bumper's UPDATE and this DELETE cannot both win, so a re-referenced chunk survives and
    # is simply collected by a later sweep if it zeroes again. Sync::Restore and
    # Sync::Conflicts.split re-reference chunks the same way and are covered by the same guard.
    def self.sweep_orphans!(user, grace: 1.hour)
      grace = grace.seconds if grace.is_a?(Numeric)
      cutoff = grace.ago
      store = Storage::ChunkStore.current
      # `<=` so grace: 0 means "sweep immediately" (a chunk zeroed at `now` is collectable)
      # rather than depending on real microseconds elapsing between the refcount touch and
      # this query — which made grace-0 sweeps non-deterministic under a frozen test clock.
      user.chunks.where(refcount: ..0).where("updated_at <= ?", cutoff).find_each do |chunk|
        hash = chunk.chunk_hash
        # The row is the claim. Lost the race (someone re-referenced it) → leave the bytes alone.
        next unless user.chunks.where(id: chunk.id, refcount: ..0).delete_all == 1

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
