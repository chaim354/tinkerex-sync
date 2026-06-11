module Storage
  # In-memory store for tests/dev. Returns fake URLs and tracks "uploaded" hashes.
  class MemoryChunkStore < ChunkStore
    def initialize
      @objects = {}
    end

    def presign_put(user_id, hash, expires_in: 900)
      "memory://put/#{key_for(user_id, hash)}"
    end

    def presign_get(user_id, hash, expires_in: 3600)
      "memory://get/#{key_for(user_id, hash)}"
    end

    def exists?(user_id, hash)
      @objects.key?(key_for(user_id, hash))
    end

    # Test helper: simulate a client having uploaded a chunk.
    def put!(user_id, hash, data = "x")
      @objects[key_for(user_id, hash)] = data
      self
    end
  end
end
