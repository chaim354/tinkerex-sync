module Sync
  # The full-tree snapshot for a device's initial sync. Paginated by node id. Files
  # include their current version's manifest so the client can build placeholders.
  #
  # Batch-loaded (G11): for a page of N nodes this issues a BOUNDED number of queries
  # (nodes page + versions-in + manifest-chunks-in), NOT O(N) per-row `find_by`s. The
  # joins are by the string `version_id`/`manifest_id` keys (there are no AR
  # associations on those), so we pluck the keys and do `where(... IN (...))` — portable
  # across SQLite + Postgres, no PG-only SQL.
  class Tree
    def self.call(user:, after_id: 0, limit: 1000)
      nodes = user.nodes.present.where("id > ?", after_id).order(:id).limit(limit).to_a

      file_nodes = nodes.select { |n| n.file? && n.current_version_id.present? }
      version_ids = file_nodes.map(&:current_version_id).uniq

      # version_id -> Version, for the file nodes on this page (one query).
      versions = version_ids.empty? ? {} :
        user.versions.where(version_id: version_ids).index_by(&:version_id)

      # manifest_id -> ordered [chunk, ...], for the manifests referenced on this page
      # (one query, grouped in memory).
      manifest_ids = versions.values.map(&:manifest_id).uniq
      manifests = Sync.load_manifests(user, manifest_ids)

      {
        nodes: nodes.map { |n| serialize(n, versions, manifests) },
        head_seq: user.head_seq,
        next_after_id: nodes.last&.id
      }
    end

    def self.serialize(node, versions, manifests)
      out = {
        node_id: node.node_id, parent_node_id: node.parent_node_id,
        name: node.name, kind: node.kind, mode: node.mode, mtime: node.mtime
      }
      if node.file? && node.current_version_id.present?
        version = versions[node.current_version_id]
        if version
          out[:version_id] = version.version_id
          out[:size] = version.size
          out[:manifest] = manifests.fetch(version.manifest_id, [])
        end
      end
      out
    end
  end
end
