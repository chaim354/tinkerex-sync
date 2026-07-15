module Sync
  # Targeted orphaned-chunk sweep — the cheap, common-case complement to the weekly,
  # list-based Sync::ChunkReaper (G4).
  #
  # The leak both reapers close: a commit uploads chunk bytes via presigned PUT and then
  # **never finalizes** (client crash between PUT and finalize, or a finalize that raised),
  # leaving bytes in object storage with NO DB row — invisible to the refcount-walking
  # Sync::Gc.sweep_orphans!. On R2 those leaked bytes cost money forever
  # (`docs/torn-writes-and-batching.md` §5).
  #
  # G4's ChunkReaper finds them by enumerating the per-user `chunks/<user_id>/` keyspace
  # (`ChunkStore#list`). That `list_objects_v2` call is billed per request on S3/R2, so G4
  # runs on a conservative WEEKLY cadence. This reaper takes the cheaper path §5 describes:
  # when a `pending_commit` row EXPIRES un-finalized we already know EXACTLY which hashes it
  # uploaded — they are in the row's manifest — so we delete precisely those objects with
  # **NO bucket `list` call at all** (DB read + targeted deletes only). That lets it run
  # frequently (hourly) and reclaim the common abandoned-upload case promptly and cheaply.
  # The weekly ChunkReaper stays as the catch-all backstop (e.g. a finalize that destroyed
  # the pending row but crashed before committing — a case with no pending row to expire).
  #
  # CRITICAL SAFETY — the SAME two guards G4 applies, so we never delete a live chunk:
  #
  #   1. **Dedup guard:** the hash must NOT be referenced by any committed `chunks` row.
  #      Chunks are content-addressed + refcounted, so a finalized version may share the
  #      very same chunk this abandoned commit uploaded. That object is live; spare it.
  #   2. **Live-pending guard:** the hash must NOT be referenced by any OTHER still-live
  #      `pending_commit`. A concurrent commit is mid-flight and about to finalize it.
  #
  # Only a hash that is orphaned under BOTH guards is deleted. Then the expired pending row
  # is destroyed (so a re-run is a clean no-op). Idempotent (delete is a no-op on an absent
  # key), best-effort on storage errors (log + continue — the object is reclaimed on a later
  # run, or by the weekly ChunkReaper), and per-user scoped (keys are `chunks/<user>/<hash>`,
  # never crossing tenants).
  class PendingCommitReaper
    # How long a legitimate un-finalized commit may live before its row is considered
    # abandoned. Mirrors Sync::ChunkReaper::PENDING_COMMIT_TTL — the two reapers must agree
    # on what "expired" means.
    TTL = Sync::ChunkReaper::PENDING_COMMIT_TTL

    # Reap one user's abandoned-upload orphans. Returns the array of reaped chunk hashes
    # (what was, or in dry_run what WOULD be, deleted). Destroys each expired pending row.
    def self.reap!(user, ttl: TTL, dry_run: false)
      ttl = ttl.seconds if ttl.is_a?(Numeric)
      cutoff = ttl.ago

      expired = user.pending_commits.where("created_at < ?", cutoff).to_a
      return [] if expired.empty?

      expired_ids = expired.map(&:id)
      store = Storage::ChunkStore.current

      # Candidate hashes: every hash any EXPIRED pending uploaded.
      candidates = Set.new
      expired.each do |pc|
        manifest_hashes(pc).each { |h| candidates << h }
      end

      # Guard sets, computed once over the candidate hashes:
      #   committed — a finalized version references it (dedup); never delete.
      #   live_pending — any NON-expired pending references it; about to finalize, never delete.
      committed = Set.new
      live_pending = Set.new
      if candidates.any?
        committed = user.chunks.where(chunk_hash: candidates.to_a).pluck(:chunk_hash).to_set
        live_pending = user.pending_commits
                           .where.not(id: expired_ids)
                           .where("created_at >= ?", cutoff)
                           .find_each
                           .flat_map { |pc| manifest_hashes(pc) }
                           .to_set
      end

      reaped = []
      candidates.each do |hash|
        next if committed.include?(hash)     # dedup: a committed version owns it
        next if live_pending.include?(hash)  # a still-live pending is about to finalize it

        # Storage-age guard (mirrors Sync::ChunkReaper): a chunk this expired commit uploaded may
        # have just been RE-uploaded by a fresh commit (content-addressed → same key) whose
        # begin/finalize hasn't shown up in the committed/live_pending snapshots yet (TOCTOU).
        # If the OBJECT is newer than the expiry cutoff, it's live — skip it. Backends that can't
        # cheaply stat one object return nil → guard is a no-op there (same as ChunkReaper's).
        lm = store.last_modified(user.id, hash)
        next if lm && lm > cutoff

        reaped << hash
        next if dry_run

        begin
          store.delete(user.id, hash)
        rescue => e
          # Best-effort, like Sync::ChunkReaper / sweep_orphans!: a transient storage error
          # must not stall the rest of the sweep. The object is reclaimed on a later run (this
          # reaper is idempotent over its candidate set) or by the weekly ChunkReaper.
          Rails.logger.warn("Sync::PendingCommitReaper storage delete failed for " \
                            "chunks/#{user.id}/#{hash}: #{e.class}: #{e.message}")
          reaped.pop
        end
      end

      # Destroy the expired rows regardless of per-hash delete outcomes — the row is what
      # marks the commit abandoned; leaving it would re-process the same hashes forever (and
      # would keep a real chunk's hash in `live_pending` from this very row on a re-run). A
      # hash whose object delete failed is still reclaimable: it has no DB row, so the weekly
      # ChunkReaper (or a future identical pending) will catch it.
      PendingCommit.where(id: expired_ids).destroy_all unless dry_run

      if reaped.any?
        Rails.logger.info("Sync::PendingCommitReaper #{dry_run ? '[dry-run] would reap' : 'reaped'} " \
                          "#{reaped.size} orphan chunk(s) from #{expired.size} expired pending " \
                          "commit(s) for user #{user.id}")
      end
      reaped
    end

    # Reap every user. Returns the total number of objects reaped across all users. Per-user
    # work is isolated — one user's error is logged and the sweep continues for the rest.
    def self.reap_all!(ttl: TTL, dry_run: false)
      total = 0
      User.find_each do |user|
        total += reap!(user, ttl:, dry_run:).size
      rescue => e
        Rails.logger.error("Sync::PendingCommitReaper failed for user #{user.id}: " \
                           "#{e.class}: #{e.message}")
      end
      total
    end

    # The chunk hashes a pending commit's manifest references (JSON: [{ "hash", ... }, ...]).
    def self.manifest_hashes(pc)
      pc.manifest.map { |c| c["hash"] || c[:hash] }
    rescue JSON::ParserError => e
      Rails.logger.warn("Sync::PendingCommitReaper skipping unparseable pending_commit " \
                        "#{pc.commit_id}: #{e.message}")
      []
    end
  end
end
