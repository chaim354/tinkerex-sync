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
    #
    # Under the parallel test runner workers share one DB but write real chunk files here;
    # without a per-worker chunk dir, a keyspace-enumerating operation (e.g.
    # Sync::ChunkReaper) in one worker would see another worker's objects. test_helper sets
    # CHUNK_STORE_WORKER per worker (see parallelize_setup) so each gets an isolated
    # keyspace. Unset (single-process / production) → the base dir.
    def root
      @root ||= begin
        name = "dev-chunks"
        if (n = ENV["CHUNK_STORE_WORKER"]).present?
          name = "dev-chunks-#{n}"
        end
        Rails.root.join("tmp", name).tap { |d| FileUtils.mkdir_p(d) }
      end
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

    # Enumerate chunks/<user_id>/* (the reaper's per-user keyspace scan). The on-disk dir
    # flattens slashes to "__", so we match the prefix and recover the hash from the suffix.
    # last_modified is the file mtime — the object's storage age.
    def list(user_id)
      prefix = key_for(user_id, "").gsub("/", "__") # "chunks__<user_id>__"
      Dir.glob(File.join(root, "#{prefix}*")).map do |path|
        hash = File.basename(path).delete_prefix(prefix)
        { hash:, last_modified: File.mtime(path) }
      end
    end

    # Test helper: simulate a client having uploaded a chunk.
    def put!(user_id, hash, data = "x")
      write_blob(user_id, hash, data)
      self
    end

    # Test helper: backdate an object's storage age so reaper grace-window tests are
    # deterministic (mirrors S3's last_modified without waiting real time).
    def set_mtime!(user_id, hash, time)
      t = time.to_time
      File.utime(t, t, path_for(user_id, hash))
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
