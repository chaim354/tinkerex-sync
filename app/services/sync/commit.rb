module Sync
  # Two-phase content commit:
  #   begin    -> record pending state, compute missing chunks, presign uploads
  #   finalize -> atomically create the version + append the changelog
  #
  # Idempotent: re-running begin with the same commit_id reuses the pending row;
  # chunk uploads are content-addressed (re-PUT is a no-op). All hot-path writes use
  # portable, fast patterns (insert_all / update_all / row lock) — no PG-only SQL.
  class Commit
    Result = Struct.new(:commit_id, :missing, :put_urls, keyword_init: true)

    # A chunk hash is a lowercase hex SHA-256 — exactly 64 hex chars. This is the ONLY
    # shape a client-supplied hash may take before it becomes a storage key
    # (chunks/<user>/<hash>) or a DB row. Rejecting anything else at the door prevents a
    # crafted hash like "../7/deadbeef" from escaping the per-user prefix on a path-based
    # S3 gateway (cross-tenant read/write) and prevents junk keys the reaper can't reclaim.
    HASH_RE = /\A[0-9a-f]{64}\z/

    # Upper bound on manifest size (chunks per commit) — clamps a memory/DB DoS from an
    # over-large manifest, mirroring the tree/changes endpoints' pagination caps. A 100k-chunk
    # manifest at the ~1 MiB avg FastCDC target is a ~100 GiB file; far past any real payload.
    MAX_MANIFEST_CHUNKS = 100_000

    class ChunksMissing < StandardError
      attr_reader :hashes
      def initialize(hashes)
        super("chunks missing")
        @hashes = hashes
      end
    end

    # Raised when a commit's manifest is malformed — a chunk hash that isn't a 64-hex
    # SHA-256, or a manifest past MAX_MANIFEST_CHUNKS. The whole commit is rejected (422)
    # rather than silently accepting a poisoned hash into the keyspace.
    class InvalidManifest < StandardError; end

    # Raised when finalizing a content commit onto a node_id that already exists as a NON-file
    # (dir/symlink). Silently flipping its kind to "file" would orphan its children/target;
    # reject with 409 instead.
    class KindConflict < StandardError; end

    # ---- Phase 1 -------------------------------------------------------------
    def self.begin(user:, device:, commit_id:, node_id:, parent_node_id:, name:,
                   base_version_id:, size:, manifest:, mode: nil, mtime: nil)
      manifest = normalize(manifest)
      if manifest.size > MAX_MANIFEST_CHUNKS
        raise InvalidManifest, "manifest too large (#{manifest.size} > #{MAX_MANIFEST_CHUNKS})"
      end
      manifest_id = manifest_id_for(manifest)
      hashes = manifest.map { |c| c["hash"] }.uniq
      bad = hashes.reject { |h| h.is_a?(String) && HASH_RE.match?(h) }
      if bad.any?
        raise InvalidManifest, "invalid chunk hash(es): #{bad.first(3).map(&:inspect).join(', ')}"
      end

      pending = user.pending_commits.find_or_initialize_by(commit_id:)
      pending.assign_attributes(
        device_id: device&.id, node_id:, parent_node_id:, name:, mode: mode&.to_i, mtime: mtime&.to_i,
        base_version_id:, manifest_id:, size: size.to_i, manifest_json: manifest.to_json
      )
      pending.save!

      present = user.chunks.where(chunk_hash: hashes).pluck(:chunk_hash).to_set
      missing = hashes.reject { |h| present.include?(h) }

      store = Storage::ChunkStore.current
      put_urls = missing.index_with { |h| store.presign_put(user.id, h) }

      Result.new(commit_id:, missing:, put_urls:)
    end

    # ---- Phase 2 -------------------------------------------------------------
    def self.finalize(user:, commit_id:, verify: false)
      pending = user.pending_commits.find_by!(commit_id:)
      manifest = pending.manifest
      manifest_id = pending.manifest_id

      if verify
        store = Storage::ChunkStore.current
        missing = manifest.map { |c| c["hash"] }.uniq.reject do |h|
          user.chunks.exists?(chunk_hash: h) || store.exists?(user.id, h)
        end
        raise ChunksMissing, missing if missing.any?
      end

      version = nil
      seq = nil
      ApplicationRecord.transaction do
        # Acquire the user-row lock + seq FIRST. Every write below (chunks/manifest/version/node,
        # all FK-bound to `users`) takes a Postgres FOR KEY SHARE lock on the users row; deferring
        # next_seq!'s FOR UPDATE until after them lets two concurrent commits each hold KEY SHARE
        # and both want UPDATE → deadlock (observed live under load). Locking up front serializes
        # a user's commits cleanly with no deadlock. (seq is only *used* at the end, but the LOCK
        # must be taken before the FK writes.)
        seq = user.next_seq!

        upsert_manifest!(user, manifest_id, manifest)
        upsert_chunks!(user, manifest)

        node = user.nodes.find_or_initialize_by(node_id: pending.node_id)
        # A content commit produces a file. Refuse to change an existing dir/symlink into a file
        # (would orphan its children/target). A brand-new node, or one already a file, is fine.
        if node.persisted? && node.kind != "file"
          raise KindConflict, "node #{pending.node_id} already exists as a #{node.kind}, cannot become a file"
        end
        prior_current = node.current_version_id
        node.assign_attributes(
          parent_node_id: pending.parent_node_id, name: pending.name,
          kind: "file", deleted: false, mode: pending.mode || node.mode || 0o644,
          mtime: pending.mtime || node.mtime
        )

        version = user.versions.create!(
          version_id: SecureRandom.uuid, node_id: pending.node_id, manifest_id:,
          size: pending.size, device_id: pending.device_id,
          parent_version_id: pending.base_version_id, created_at: Time.current
        )

        # Conflict iff the client based this edit on a version that is no longer current
        # (someone committed in between — e.g. edited offline, then reconnected). Instead
        # of silently last-writer-wins, keep the node pointed at the existing version,
        # record the divergence, and emit a `conflict` change so every device learns to
        # ask the user. Both versions are stored regardless (chunks are content-addressed
        # + refcounted, so the extra cost is just the delta).
        is_conflict = node.persisted? && prior_current.present? &&
                      pending.base_version_id.present? && pending.base_version_id != prior_current

        # ...but a divergence from the SAME device is not a real conflict — it's that device's own
        # sequential write racing its echo (e.g. the sync daemon pushes a rename, pulls its own
        # changelog entry back which advances current_version, then a follow-up/retry push still
        # carries the pre-echo base). A genuine conflict needs a *different* device to have moved
        # current_version. So fast-forward when the prior current version came from this same device.
        if is_conflict
          prior_version = user.versions.find_by(version_id: prior_current)
          if prior_version && pending.device_id.present? && prior_version.device_id == pending.device_id
            is_conflict = false
          end
        end

        if is_conflict
          # N-way: key the conflict by its INCOMING version so 3+ concurrent divergent edits each
          # get their own row. The old find_or_initialize_by(node_id:) overwrote incoming_version_id,
          # so a later device's stale push REPLACED an earlier device's incoming version in the open
          # row — that earlier edit then survived only in version history, referenced by no conflict,
          # invisible to the resolution UI (silent loss from the user's view). Keying by the incoming
          # version gives one row per divergent edit; an idempotent re-finalize of the same version
          # reuses its row.
          c = user.conflicts.unresolved
                  .find_or_initialize_by(node_id: pending.node_id, incoming_version_id: version.version_id)
          c.current_version_id = prior_current
          c.save!
          op = "conflict"
        else
          node.current_version_id = version.version_id
          op = "put"
        end

        node.updated_seq = seq
        node.save!
        user.changelog_entries.create!(
          seq:, node_id: pending.node_id, op:,
          version_id: version.version_id, created_at: Time.current
        )
        pending.destroy!
      end
      [ version, seq ]
    end

    # ---- helpers -------------------------------------------------------------

    # manifest_id = SHA-256 of the ordered chunk-hash list (matches the Rust client).
    def self.manifest_id_for(manifest)
      Digest::SHA256.hexdigest(manifest.map { |c| c["hash"] }.join)
    end

    def self.normalize(manifest)
      Array(manifest).map do |c|
        h = c.respond_to?(:to_h) ? c.to_h : c
        { "hash" => h["hash"] || h[:hash],
          "offset" => (h["offset"] || h[:offset]).to_i,
          "length" => (h["length"] || h[:length]).to_i }
      end
    end

    def self.upsert_manifest!(user, manifest_id, manifest)
      return if ManifestChunk.manifest_exists?(user_id: user.id, manifest_id:)
      rows = manifest.each_with_index.map do |c, i|
        { user_id: user.id, manifest_id:, seq: i,
          chunk_hash: c["hash"], offset: c["offset"], length: c["length"] }
      end
      ManifestChunk.insert_all(rows) if rows.any?
    end

    # One refcount per unique chunk per version. New chunks inserted at refcount 1.
    def self.upsert_chunks!(user, manifest)
      sizes = {}
      manifest.each { |c| sizes[c["hash"]] = c["length"] }
      hashes = sizes.keys
      existing = user.chunks.where(chunk_hash: hashes).pluck(:chunk_hash)
      new_hashes = hashes - existing
      if new_hashes.any?
        now = Time.current
        Chunk.insert_all(new_hashes.map { |h|
          { user_id: user.id, chunk_hash: h, size: sizes[h], refcount: 1,
            created_at: now, updated_at: now }
        })
      end
      # Through Gc.touch_refcounts! so the bump also moves `updated_at` — that column is what
      # Gc.sweep_orphans!'s grace window filters on, and a dedup against an already-zeroed chunk
      # is exactly the re-reference the window exists to protect. See its comment.
      Sync::Gc.touch_refcounts!(user.chunks.where(chunk_hash: existing), by: 1) if existing.any?
    end
  end
end
