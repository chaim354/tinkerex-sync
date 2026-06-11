module Sync
  # The pull delta: ordered changelog entries where seq > cursor, each carrying the
  # node's current state and (for content commits) the version's manifest so the
  # client can update its local tree and dehydrate changed placeholders.
  #
  # Note: this does per-entry lookups (fine for incremental deltas, which are small).
  # The bulk path is Sync::Tree. A future optimization preloads nodes/versions.
  class Changes
    def self.call(user:, since:, limit: 500)
      entries = user.changelog_entries.since(since).limit(limit).to_a
      {
        changes: entries.map { |e| serialize(user, e) },
        head_seq: user.head_seq
      }
    end

    def self.serialize(user, entry)
      out = { seq: entry.seq, op: entry.op, node_id: entry.node_id }
      node = user.nodes.find_by(node_id: entry.node_id)
      if node
        out[:node] = {
          node_id: node.node_id, parent_node_id: node.parent_node_id,
          name: node.name, kind: node.kind, deleted: node.deleted
        }
      end
      if entry.op == "put" && entry.version_id.present?
        version = user.versions.find_by(version_id: entry.version_id)
        if version
          out[:version] = { version_id: version.version_id, manifest_id: version.manifest_id, size: version.size }
          out[:manifest] = version.manifest_chunks.map do |c|
            { hash: c.chunk_hash, offset: c.offset, length: c.length }
          end
        end
      end
      out
    end
  end
end
