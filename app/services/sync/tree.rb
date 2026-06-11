module Sync
  # The full-tree snapshot for a device's initial sync. Paginated by node id. Files
  # include their current version's manifest so the client can build placeholders.
  class Tree
    def self.call(user:, after_id: 0, limit: 1000)
      nodes = user.nodes.present.where("id > ?", after_id).order(:id).limit(limit).to_a
      {
        nodes: nodes.map { |n| serialize(user, n) },
        head_seq: user.head_seq,
        next_after_id: nodes.last&.id
      }
    end

    def self.serialize(user, node)
      out = {
        node_id: node.node_id, parent_node_id: node.parent_node_id,
        name: node.name, kind: node.kind
      }
      if node.file? && node.current_version_id.present?
        version = node.current_version
        if version
          out[:version_id] = version.version_id
          out[:size] = version.size
          out[:manifest] = version.manifest_chunks.map do |c|
            { hash: c.chunk_hash, offset: c.offset, length: c.length }
          end
        end
      end
      out
    end
  end
end
