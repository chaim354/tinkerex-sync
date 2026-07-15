module Storage
  # A REAL HTTP data-plane chunk store backed by the local filesystem — the self-hosted /
  # single-box analogue of S3/R2, with NO external object store (no SeaweedFS/MinIO) and NO
  # copyleft dependency. It exists so the full data plane (client uploads chunk bytes via
  # presigned PUT, another device hydrates them via presigned GET) can be exercised end-to-end
  # on one machine — e.g. the two-device REAL-MOUNT tests, where two live mounts must actually
  # move bytes between each other.
  #
  # Unlike MemoryChunkStore (which mints fake `memory://` URLs that no HTTP client can use, so
  # it's control-plane only), this presigns real `http(s)://<host>/v1/chunks/blob/...?exp&sig`
  # URLs that the client's plain PUT/GET hit. The path is **HMAC-signed with the Rails secret**
  # (keyed by user_id + hash + expiry), so a token can't retarget it to another user's key —
  # the same untamperable, per-user-scoped property as the SigV4 keys in production (CLAUDE.md
  # §8). Bytes still never flow through the *control* endpoints; the blob endpoints are the
  # storage tier, just colocated.
  #
  # Set `STORAGE_BACKEND=local` and (optionally) `CHUNK_LOCAL_DIR` (default tmp/chunk-store) and
  # `CHUNK_PUBLIC_URL` (the base the *client* reaches, default http://localhost:<port> inferred
  # from the request — pass it explicitly for a non-localhost client).
  class LocalChunkStore < ChunkStore
    def self.from_env
      new(
        dir:        ENV.fetch("CHUNK_LOCAL_DIR", Rails.root.join("tmp", "chunk-store").to_s),
        public_url: ENV["CHUNK_PUBLIC_URL"] # nil → BlobController infers from the request host
      )
    end

    attr_reader :dir, :public_url

    def initialize(dir:, public_url: nil)
      @dir = dir
      @public_url = public_url&.sub(%r{/+\z}, "")
      FileUtils.mkdir_p(@dir)
    end

    # ---- presigning (the part ChunkStore callers use) --------------------------------------

    def presign_put(user_id, hash, expires_in: 900)
      blob_url(user_id, hash, expires_in)
    end

    def presign_get(user_id, hash, expires_in: 3600)
      blob_url(user_id, hash, expires_in)
    end

    def exists?(user_id, hash)
      File.exist?(path_for(user_id, hash))
    end

    def last_modified(user_id, hash)
      p = path_for(user_id, hash)
      File.exist?(p) ? File.mtime(p) : nil
    end

    # Idempotent (mirrors S3/Memory): deleting an absent key is a no-op.
    def delete(user_id, hash)
      FileUtils.rm_f(path_for(user_id, hash))
      nil
    end

    # Enumerate <dir>/chunks/<user_id>/* for the storage-orphan reaper. last_modified is
    # the file mtime (the object's storage age).
    def list(user_id)
      base = File.join(@dir, "chunks", user_id.to_s)
      return [] unless Dir.exist?(base)
      Dir.children(base).filter_map do |hash|
        path = File.join(base, hash)
        next unless File.file?(path)
        { hash:, last_modified: File.mtime(path) }
      end
    end

    # Test helper: backdate an object's storage age (deterministic grace-window tests).
    def set_mtime!(user_id, hash, time)
      t = time.to_time
      File.utime(t, t, path_for(user_id, hash))
      self
    end

    # ---- the storage tier (called by V1::Chunks::BlobController, not by sync callers) -------

    # On-disk path for a chunk. The hash is content-addressed (hex), the user_id an integer, so
    # neither can contain path-traversal characters — but we still constrain to the store root.
    def path_for(user_id, hash)
      raise ArgumentError, "bad hash" unless hash.match?(/\A[0-9a-f]{8,128}\z/)
      File.join(@dir, "chunks", user_id.to_s, hash)
    end

    def read(user_id, hash)
      p = path_for(user_id, hash)
      File.exist?(p) ? File.binread(p) : nil
    end

    def write(user_id, hash, bytes)
      p = path_for(user_id, hash)
      FileUtils.mkdir_p(File.dirname(p))
      # Atomic: write to a temp then rename, so a concurrent reader never sees a partial blob
      # (two devices may PUT the same content-addressed chunk at once — last writer is identical).
      tmp = "#{p}.#{SecureRandom.hex(6)}.tmp"
      File.binwrite(tmp, bytes)
      File.rename(tmp, p)
      nil
    end

    # ---- HMAC URL signing ------------------------------------------------------------------

    # The shared secret for signing blob URLs. Reuses the Rails secret_key_base so there's no new
    # config; rotating it just invalidates outstanding (short-lived) URLs.
    def self.signing_key
      Rails.application.secret_key_base
    end

    # Verify a presented (user_id, hash, exp, sig). Constant-time compare; rejects expired URLs.
    def self.verify(user_id, hash, exp, sig)
      return false if exp.to_i < Time.now.to_i
      expected = sign(user_id, hash, exp)
      ActiveSupport::SecurityUtils.secure_compare(sig.to_s, expected)
    end

    def self.sign(user_id, hash, exp)
      data = "#{user_id}\n#{hash}\n#{exp}"
      OpenSSL::HMAC.hexdigest("SHA256", signing_key, data)
    end

    private

    def blob_url(user_id, hash, expires_in)
      exp = (Time.now + expires_in).to_i
      sig = self.class.sign(user_id, hash, exp)
      base = @public_url || PUBLIC_URL_OVERRIDE.value || "http://localhost:3000"
      "#{base}/v1/chunks/blob/#{user_id}/#{hash}?exp=#{exp}&sig=#{sig}"
    end

    # When no CHUNK_PUBLIC_URL is configured, the BlobController stashes the current request's
    # base URL here (per-thread) so presigned URLs point back at the host the client is talking to
    # — makes the single-box dev/test case zero-config.
    PUBLIC_URL_OVERRIDE = Concurrent::ThreadLocalVar.new { nil }
  end
end
