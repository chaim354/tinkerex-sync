module Sync
  # G4 — the orphaned-chunk reaper.
  #
  # `Sync::Gc.sweep_orphans!` reclaims chunks by walking *DB rows* (refcount-0 `chunks`).
  # But a commit that uploads chunk bytes via presigned PUT and then **never finalizes**
  # (client crash between PUT and finalize, or a finalize that raises) leaves bytes in
  # object storage with **no DB row at all** — no `chunks` record, no `manifest_chunks`.
  # The refcount sweep can't see them; on R2 those leaked bytes cost money forever
  # (`docs/torn-writes-and-batching.md` §5).
  #
  # This reaper closes that gap from the storage side: it enumerates the per-user keyspace
  # (`chunks/<user_id>/`) and deletes any object that is genuinely orphaned. An object is
  # reaped **only** when ALL of these hold:
  #
  #   1. No committed `chunks` row references its hash (it is not a live, finalized chunk).
  #   2. No in-flight `pending_commits` references its hash (a commit is mid-flight and is
  #      about to finalize a version that will create the `chunks` row).
  #   3. Its storage object is older than `grace` (the longest plausible commit lifetime).
  #
  # The grace window mirrors git-gc's prune grace-period discipline (`torn-writes` §2): an
  # upload that has just landed but whose `finalize` hasn't run yet must NOT be reaped. We
  # default the grace to PENDING_COMMIT_TTL so it strictly exceeds how long a legitimate
  # commit can stay un-finalized, and we *additionally* cross-check `pending_commits`
  # regardless of object age (a slow multi-chunk upload, or a retried `begin`, can leave an
  # early chunk old while the commit is still live).
  #
  # Safe to re-run (idempotent — delete is a no-op on an absent key), per-user scoped
  # (keys are `chunks/<user_id>/<hash>`, never crossing tenants), and supports a dry-run
  # that reports what it WOULD delete without touching storage.
  class ChunkReaper
    # The longest a legitimate un-finalized commit should live. Any orphan storage object
    # older than this with no `chunks` row and no `pending_commits` reference is genuinely
    # abandoned. Generous on purpose — the cost of waiting is a few KB of leaked bytes for a
    # few hours; the cost of reaping too eagerly is deleting an in-flight upload. Pair this
    # with a periodic `pending_commits` expiry if you want the window tighter.
    PENDING_COMMIT_TTL = 24.hours

    # Reap one user's leaked objects. Returns the array of reaped chunk hashes (what was, or
    # in dry_run what WOULD be, deleted).
    def self.reap!(user, grace: PENDING_COMMIT_TTL, dry_run: false)
      grace = grace.seconds if grace.is_a?(Numeric)
      cutoff = grace.ago
      store = Storage::ChunkStore.current

      objects = store.list(user.id)
      return [] if objects.empty?

      # Set of hashes that are protected and must never be reaped:
      #   - committed chunks (a finalized version references them)
      #   - in-flight pending-commit manifests (about to be finalized)
      hashes = objects.map { |o| o[:hash] }
      committed = user.chunks.where(chunk_hash: hashes).pluck(:chunk_hash).to_set
      pending = pending_hashes(user)

      reaped = []
      objects.each do |obj|
        hash = obj[:hash]
        next if committed.include?(hash)              # live, finalized chunk
        next if pending.include?(hash)                # in-flight commit (any age)
        next if obj[:last_modified] && obj[:last_modified] > cutoff # within grace → maybe mid-commit

        reaped << hash
        next if dry_run

        begin
          store.delete(user.id, hash)
        rescue => e
          # Best-effort, like sweep_orphans!: a transient storage error must not stall the
          # rest of the sweep. The object is reclaimed on a later run (reaper is idempotent).
          Rails.logger.warn("Sync::ChunkReaper storage delete failed for " \
                            "chunks/#{user.id}/#{hash}: #{e.class}: #{e.message}")
          reaped.pop
        end
      end

      if reaped.any?
        Rails.logger.info("Sync::ChunkReaper #{dry_run ? '[dry-run] would reap' : 'reaped'} " \
                          "#{reaped.size} orphan chunk(s) for user #{user.id}")
      end
      reaped
    end

    # Reap every user. Returns the total number of objects reaped across all users. Per-user
    # work is isolated — one user's error is logged and the sweep continues for the rest.
    def self.reap_all!(grace: PENDING_COMMIT_TTL, dry_run: false)
      total = 0
      User.find_each do |user|
        total += reap!(user, grace:, dry_run:).size
      rescue => e
        Rails.logger.error("Sync::ChunkReaper failed for user #{user.id}: #{e.class}: #{e.message}")
      end
      total
    end

    # All chunk hashes referenced by a user's in-flight pending commits. A pending commit's
    # manifest is JSON ([{ "hash", "offset", "length" }, ...]); we union every hash so an
    # object an active commit is about to finalize is never reaped, regardless of its age.
    #
    # **DO NOT ADD AN AGE FILTER HERE.** Every row, no filter, is what makes this the wider
    # of the two pending guards, and the backstop must be the wider one: filtering by
    # `created_at` would let this reaper delete a chunk a slow multi-chunk commit — or a
    # retried `begin` — is still about to finalize. Sync::PendingCommitReaper deliberately
    # asks the NARROWER question (it excludes the expired rows it is destroying in the same
    # call); that divergence is stated there and pinned in `pending_commit_reaper_test.rb`.
    def self.pending_hashes(user)
      set = Set.new
      user.pending_commits.find_each do |pc|
        pc.manifest.each { |c| set << (c["hash"] || c[:hash]) }
      rescue JSON::ParserError => e
        Rails.logger.warn("Sync::ChunkReaper skipping unparseable pending_commit " \
                          "#{pc.commit_id} for user #{user.id}: #{e.message}")
      end
      set
    end
  end
end
