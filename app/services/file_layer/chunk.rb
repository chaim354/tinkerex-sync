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
      node = live_node!(user, node_id)

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
      # A tombstoned node is GONE on every backend (contract:
      # test_contract_read_raises_not_found_for_a_deleted_node). Checked BEFORE resolving the
      # version, and OUTSIDE the branch below, because the by-token path queries `versions` and
      # would otherwise never consult `nodes` at all — leaving the asymmetry inside this very
      # method, on the path every production caller actually uses (contract:
      # test_contract_read_at_a_token_captured_before_deletion_raises_not_found).
      node = live_node!(user, node_id)

      version =
        if content_token.present?
          user.versions.find_by(node_id:, version_id: content_token)
        else
          node.current_version
        end
      raise NotFound, "no version for node #{node_id.inspect}" unless version

      store = Storage::ChunkStore.current
      buf = +"".b
      version.manifest_chunks.each do |mc|
        bytes = self.class.fetch(store, user.id, mc.chunk_hash)
        raise NotFound, "missing chunk #{mc.chunk_hash}" if bytes.nil?
        buf << bytes.b
        raise NotFound, "file exceeds #{MAX_BYTES} bytes" if buf.bytesize > MAX_BYTES
      end
      buf
    end

    # Normalize over the chunk-store backends.
    #   - memory store exposes read_blob (tests/dev)
    #   - local filesystem store exposes read
    #   - S3 store exposes presign_get -> pull the bytes over the presigned GET
    #
    # Returns the bytes, or nil ONLY when the chunk is genuinely absent (a 404 from the
    # presigned GET). A non-404 HTTP error (403 auth, 5xx) or a network error is a TRANSIENT
    # failure -> raise FetchError so the caller retries instead of treating it as permanently
    # missing.
    def self.fetch(store, user_id, hash)
      if store.respond_to?(:read_blob)
        store.read_blob(user_id, hash)
      elsif store.respond_to?(:read)
        store.read(user_id, hash)
      else
        http_get(store.presign_get(user_id, hash))
      end
    rescue OpenURI::HTTPError => e
      # io.status is ["404", "Not Found"]; 404 means the object isn't there (terminal, nil ->
      # NotFound upstream). Anything else (403/5xx) is transient -> FetchError.
      status = e.io.status.first.to_i rescue 0
      return nil if status == 404
      raise FetchError, "chunk GET #{hash}: HTTP #{status} (#{e.message})"
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout,
           Net::ReadTimeout, Timeout::Error => e
      raise FetchError, "chunk GET #{hash}: #{e.class} (#{e.message})"
    end

    # The HTTP fetch seam (presigned GET -> bytes). Extracted so it can be exercised/faulted
    # in isolation; the edge tests stub THIS method. open-uri raises OpenURI::HTTPError for
    # non-2xx, carrying the status.
    def self.http_get(url)
      require "open-uri"
      require "net/http"
      URI.parse(url).open(&:read)
    end

    # NOTE: only affects the instance methods below; `def self.` methods above stay public.
    private

    # The liveness guard both stat and read must apply. Shared rather than duplicated because
    # stat and read answering DIFFERENTLY for the same node is precisely the bug this closes
    # (§9a-1) — one copy means they cannot drift apart again.
    #
    # The message avoids internal jargon and does not distinguish deleted from never-existed:
    # it reaches end users through preview.error (rendered into the previews API JSON), and to
    # a caller holding a node_id the two states are the same answer — the file isn't there.
    def live_node!(user, node_id)
      user.nodes.present.find_by(node_id:) ||
        raise(NotFound, "node #{node_id.inspect} is deleted or does not exist")
    end
  end
end
