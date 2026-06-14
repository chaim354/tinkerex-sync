module Storage
  # Base + factory for the content-addressed chunk store. Concrete stores
  # (S3/R2, Memory) presign PUT (upload missing chunks) and GET (hydration) so file
  # bytes flow client <-> storage directly — Rails never handles chunk bytes.
  class ChunkStore
    class << self
      attr_writer :current

      def current
        @current ||= build
      end

      def reset!
        @current = nil
      end

      def build
        case ENV.fetch("STORAGE_BACKEND", Rails.env.test? ? "memory" : "s3")
        when "memory" then MemoryChunkStore.new
        when "s3"     then S3ChunkStore.from_env
        else raise ArgumentError, "unknown STORAGE_BACKEND"
        end
      end
    end

    # Per-user prefix isolates tenants and bounds the read token's scope.
    def key_for(user_id, hash)
      "chunks/#{user_id}/#{hash}"
    end

    def presign_put(_user_id, _hash, expires_in: 900) = raise(NotImplementedError)
    def presign_get(_user_id, _hash, expires_in: 3600) = raise(NotImplementedError)
    def exists?(_user_id, _hash) = raise(NotImplementedError)

    # Delete the object at chunks/<user>/<hash>. The GC sweep calls this AFTER the chunk
    # row is gone, so it MUST be idempotent (tolerate an already-deleted key). The base
    # is a safe no-op so a backend without an admin delete never blocks a sweep.
    def delete(_user_id, _hash) = nil
  end
end
