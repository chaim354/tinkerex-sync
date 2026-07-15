module FileLayer
  # The chunk-store adapter: the sync engine's content-addressed store, where a file's bytes
  # are the ordered manifest_chunks of an immutable version. This is the ONLY adapter that
  # can restore history, so its content_token is a version UUID.
  #
  # Runs server-side (preview jobs), so it reads chunks directly rather than via presigned
  # URLs where the store allows it.
  class Chunk
    def capabilities
      Capabilities.new(versioned: true, syncable: true, presignable: true)
    end

    def stat(user, node_id:)
      node = user.nodes.present.find_by(node_id:)
      raise NotFound, "no node #{node_id.inspect}" unless node

      FileInfo.new(
        node_id: node.node_id,
        name: node.name,
        kind: node.kind,
        size: node.current_version&.size.to_i,
        mtime: node.mtime,
        content_token: node.current_version_id
      )
    end

    def read(user, node_id:, content_token: nil)
      raise NotImplementedError
    end
  end
end
