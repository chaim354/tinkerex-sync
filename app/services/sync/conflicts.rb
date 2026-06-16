module Sync
  # Resolving a file divergence. Two outcomes the user picks from:
  #   keep(version_id) — make one side current; the other stays in history.
  #   split            — keep both; the incoming side becomes a new sibling file
  #                      ("foo (conflict from <device> <when>).ext"), reusing its
  #                      manifest so it costs ZERO new blocks.
  class Conflicts
    # Unresolved conflicts with both sides' details (which device, when, how big) so the
    # client can show a "which is current?" prompt.
    def self.list(user:)
      user.conflicts.unresolved.order(:created_at).map do |c|
        node = user.nodes.find_by(node_id: c.node_id)
        {
          node_id: c.node_id,
          name: node&.name,
          current: version_detail(user, c.current_version_id),
          incoming: version_detail(user, c.incoming_version_id)
        }
      end
    end

    # Keep one side as current, resolve the conflict, and propagate (a `put` so every
    # device converges — the device holding the other version overwrites its local copy).
    def self.keep(user:, node_id:, version_id:)
      c = user.conflicts.unresolved.find_by!(node_id:)
      unless [ c.current_version_id, c.incoming_version_id ].include?(version_id)
        raise ArgumentError, "version is not part of this conflict"
      end
      seq = nil
      ApplicationRecord.transaction do
        # Lock user row + seq first (FK-deadlock avoidance — see Sync::Commit#finalize).
        seq = user.next_seq!
        node = user.nodes.find_by!(node_id:)
        node.current_version_id = version_id
        node.updated_seq = seq
        node.save!
        user.changelog_entries.create!(seq:, node_id:, op: "put", version_id:, created_at: Time.current)
        c.update!(resolved_at: Time.current)
      end
      seq
    end

    # Keep both: the node stays at its current version; the incoming version becomes a new
    # sibling file. Reuses the incoming manifest (refcount += 1) — no re-upload.
    def self.split(user:, node_id:)
      c = user.conflicts.unresolved.find_by!(node_id:)
      new_node_id = SecureRandom.uuid
      seq = nil
      ApplicationRecord.transaction do
        # Lock user row + seq first (FK-deadlock avoidance — see Sync::Commit#finalize).
        seq = user.next_seq!
        node = user.nodes.find_by!(node_id:)
        incoming = user.versions.find_by!(version_id: c.incoming_version_id)
        bump_refcounts!(user, incoming.manifest_id)

        copy = user.nodes.create!(
          node_id: new_node_id, parent_node_id: node.parent_node_id,
          name: conflicted_name(user, node.name, incoming), kind: "file", deleted: false
        )
        v = user.versions.create!(
          version_id: SecureRandom.uuid, node_id: new_node_id, manifest_id: incoming.manifest_id,
          size: incoming.size, device_id: incoming.device_id, created_at: Time.current
        )
        copy.update!(current_version_id: v.version_id, updated_seq: seq)
        user.changelog_entries.create!(seq:, node_id: new_node_id, op: "put", version_id: v.version_id, created_at: Time.current)
        c.update!(resolved_at: Time.current)
      end
      [ new_node_id, seq ]
    end

    def self.version_detail(user, version_id)
      v = user.versions.find_by(version_id:)
      return nil unless v
      { version_id: v.version_id, size: v.size, created_at: v.created_at,
        device_name: device_name(user, v.device_id) }
    end

    def self.device_name(user, device_id)
      (device_id && user.devices.find_by(id: device_id)&.name) || "another device"
    end

    def self.conflicted_name(user, name, version)
      who = device_name(user, version.device_id)
      stamp = version.created_at.strftime("%Y-%m-%d %H%M")
      ext = File.extname(name)
      base = ext.empty? ? name : name[0...-ext.length]
      "#{base} (conflict from #{who} #{stamp})#{ext}"
    end

    def self.bump_refcounts!(user, manifest_id)
      hashes = ManifestChunk.where(user_id: user.id, manifest_id:).distinct.pluck(:chunk_hash)
      user.chunks.where(chunk_hash: hashes).update_all("refcount = refcount + 1") if hashes.any?
    end
  end
end
