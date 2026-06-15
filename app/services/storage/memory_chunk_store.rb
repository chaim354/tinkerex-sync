module Storage
  # In-memory / local-disk store for tests & dev.
  #
  # PRODUCTION uses S3ChunkStore: presigned URLs point straight at object storage so
  # chunk bytes flow browser <-> storage and NEVER through Rails. The memory store can't
  # presign a real off-box URL, so for the web UI (and tests) to actually round-trip
  # bytes it presigns to a *dev-only* local blob endpoint (DevBlobsController, mounted at
  # /dev/blobs and only routed outside production). This mirrors ActiveStorage's disk
  # service: the same browser PUT-then-GET shape as S3, just served locally. The bytes
  # still never go through the v1/Rails control plane — they hit a dedicated blob route
  # backed by this store's on-disk dir. In production STORAGE_BACKEND=s3, so this code
  # path and route do not exist.
  class MemoryChunkStore < ChunkStore
    # Shared on-disk dir so presigned PUT (one request) and GET (a later request) see
    # the same bytes across requests/processes. Lives under tmp; safe to wipe.
    def root
      @root ||= Rails.root.join("tmp", "dev-chunks").tap { |d| FileUtils.mkdir_p(d) }
    end

    def path_for(user_id, hash)
      path_for_key(key_for(user_id, hash))
    end

    # On-disk path for a full storage key (chunks/<user_id>/<hash>). Slashes flattened so
    # everything stays in one dir; key is the source of truth.
    def path_for_key(key)
      File.join(root, key.gsub("/", "__"))
    end

    def presign_put(user_id, hash, expires_in: 900)
      blob_url(user_id, hash)
    end

    def presign_get(user_id, hash, expires_in: 3600)
      blob_url(user_id, hash)
    end

    def exists?(user_id, hash)
      File.exist?(path_for(user_id, hash))
    end

    # Idempotent: deleting an absent key is a no-op (mirrors S3's delete semantics).
    def delete(user_id, hash)
      FileUtils.rm_f(path_for(user_id, hash))
      nil
    end

    # Used by DevBlobsController (the dev/test blob endpoint) to persist/serve bytes,
    # keyed by the full storage key (chunks/<user_id>/<hash>) the presigned URL carries.
    def write_blob(user_id, hash, data)
      File.binwrite(path_for(user_id, hash), data)
    end

    def read_blob(user_id, hash)
      return nil unless exists?(user_id, hash)
      File.binread(path_for(user_id, hash))
    end

    def write_blob_key(key, data)
      File.binwrite(path_for_key(key), data)
    end

    def read_blob_key(key)
      p = path_for_key(key)
      File.exist?(p) ? File.binread(p) : nil
    end

    # Test helper: simulate a client having uploaded a chunk.
    def put!(user_id, hash, data = "x")
      write_blob(user_id, hash, data)
      self
    end

    private

    # A relative dev-blob URL the browser PUTs/GETs. Embeds the SAME per-user key shape
    # as the S3 store (chunks/<user_id>/<hash>) so the per-tenant isolation invariant holds.
    def blob_url(user_id, hash)
      "/dev/blobs/#{key_for(user_id, hash)}"
    end
  end
end
