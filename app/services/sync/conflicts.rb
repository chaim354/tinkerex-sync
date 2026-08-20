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

    # Keep one side as current, resolve ALL the node's conflicts, and propagate (a `put` so every
    # device converges — devices holding the other versions overwrite their local copy). N-way:
    # a node may have several open conflict rows (one per divergent incoming version); keeping one
    # version is a decision for the whole node, so every divergent side is discarded (left in
    # history) and every conflict row is resolved.
    def self.keep(user:, node_id:, version_id:)
      conflicts = user.conflicts.unresolved.where(node_id:).to_a
      raise ActiveRecord::RecordNotFound, "no unresolved conflict for node" if conflicts.empty?
      valid = conflicts.flat_map { |c| [ c.current_version_id, c.incoming_version_id ] }.uniq
      unless valid.include?(version_id)
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
        user.conflicts.unresolved.where(node_id:).update_all(resolved_at: Time.current)
      end
      seq
    end

    # Keep all: the node stays at its current version; EACH divergent incoming version becomes a
    # new sibling file. Reuses each incoming manifest (refcount += 1) — no re-upload. N-way: with
    # several open conflict rows, every losing side is split into its own sibling. Returns the list
    # of new sibling node_ids and the final seq (kept as [first_node_id, seq] for 2-way callers).
    def self.split(user:, node_id:)
      conflicts = user.conflicts.unresolved.where(node_id:).order(:created_at, :id).to_a
      raise ActiveRecord::RecordNotFound, "no unresolved conflict for node" if conflicts.empty?
      new_node_ids = []
      seq = nil
      ApplicationRecord.transaction do
        # Lock user row + seq first (FK-deadlock avoidance — see Sync::Commit#finalize). Each
        # sibling gets its OWN changelog seq ((user_id, seq) is unique), so mint one per side.
        seq = user.next_seq!
        node = user.nodes.find_by!(node_id:)
        # Dedup by incoming version so two conflict rows referencing the same version (shouldn't
        # happen with the unique index, but be defensive) yield one sibling.
        seen = {}
        conflicts.each do |c|
          next if seen[c.incoming_version_id]
          seen[c.incoming_version_id] = true
          incoming = user.versions.find_by!(version_id: c.incoming_version_id)
          bump_refcounts!(user, incoming.manifest_id)

          this_seq = new_node_ids.empty? ? seq : user.next_seq!
          new_node_id = SecureRandom.uuid
          new_node_ids << new_node_id
          copy = user.nodes.create!(
            node_id: new_node_id, parent_node_id: node.parent_node_id,
            name: conflicted_name(user, node.name, incoming), kind: "file", deleted: false
          )
          v = user.versions.create!(
            version_id: SecureRandom.uuid, node_id: new_node_id, manifest_id: incoming.manifest_id,
            size: incoming.size, device_id: incoming.device_id, created_at: Time.current
          )
          copy.update!(current_version_id: v.version_id, updated_seq: this_seq)
          user.changelog_entries.create!(seq: this_seq, node_id: new_node_id, op: "put", version_id: v.version_id, created_at: Time.current)
          seq = this_seq
        end
        user.conflicts.unresolved.where(node_id:).update_all(resolved_at: Time.current)
      end
      [ new_node_ids.first, seq, new_node_ids ]
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
      hashes = Sync::ManifestChunk.where(user_id: user.id, manifest_id:).distinct.pluck(:chunk_hash)
      # Gc.touch_refcounts!, not a bare update_all — a split re-references chunks that may sit at
      # refcount 0 awaiting a sweep, and `updated_at` is what that sweep's grace window reads.
      Sync::Gc.touch_refcounts!(user.chunks.where(chunk_hash: hashes), by: 1) if hashes.any?
    end
  end
end
