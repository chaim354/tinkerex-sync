module Sync
  # Restore a file to a previous version. Creates a NEW version reusing the old
  # version's manifest (chunks already exist — just bump their refcounts), then
  # propagates it like any other change. Lossless, cheap, version-native.
  class Restore
    def self.call(user:, node_id:, version_id:)
      old = user.versions.find_by!(version_id:, node_id:)
      node = user.nodes.find_by!(node_id:)

      version = nil
      seq = nil
      ApplicationRecord.transaction do
        # Lock the user row + allocate seq FIRST, before the FK-bound version/node writes — see
        # Sync::Commit#finalize for the FK-KEY-SHARE-vs-FOR-UPDATE deadlock this avoids on Postgres.
        seq = user.next_seq!

        hashes = ManifestChunk
                 .where(user_id: user.id, manifest_id: old.manifest_id)
                 .distinct.pluck(:chunk_hash)
        # Gc.touch_refcounts!, not a bare update_all: a restore re-references chunks that may sit
        # at refcount 0 awaiting a sweep, and `updated_at` is what that sweep's grace window reads.
        Sync::Gc.touch_refcounts!(user.chunks.where(chunk_hash: hashes), by: 1) if hashes.any?

        version = user.versions.create!(
          version_id: SecureRandom.uuid, node_id:, manifest_id: old.manifest_id,
          size: old.size, parent_version_id: node.current_version_id, created_at: Time.current
        )
        node.current_version_id = version.version_id
        node.deleted = false

        node.updated_seq = seq
        node.save!
        user.changelog_entries.create!(
          seq:, node_id:, op: "put", version_id: version.version_id, created_at: Time.current
        )
      end
      [ version, seq ]
    end
  end
end
