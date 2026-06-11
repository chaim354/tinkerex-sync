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
        hashes = ManifestChunk
                 .where(user_id: user.id, manifest_id: old.manifest_id)
                 .distinct.pluck(:chunk_hash)
        user.chunks.where(chunk_hash: hashes).update_all("refcount = refcount + 1") if hashes.any?

        version = user.versions.create!(
          version_id: SecureRandom.uuid, node_id:, manifest_id: old.manifest_id,
          size: old.size, parent_version_id: node.current_version_id, created_at: Time.current
        )
        node.current_version_id = version.version_id
        node.deleted = false

        seq = user.next_seq!
        node.updated_seq = seq
        node.save!
        user.changelog_entries.create!(
          seq:, node_id:, op: "put", version_id: version.version_id, created_at: Time.current
        )
      end
      [version, seq]
    end
  end
end
