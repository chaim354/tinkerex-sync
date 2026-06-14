require "test_helper"

module Storage
  # The store must expose delete(user_id, hash) so the GC sweep can free object-storage
  # bytes for refcount-0 chunks. Memory is a safe no-op-ish tracker; S3 issues delete_object
  # against the per-user key chunks/<user>/<hash>.
  class ChunkStoreTest < ActiveSupport::TestCase
    setup { Storage::ChunkStore.reset! }
    teardown { Storage::ChunkStore.reset! }

    test "memory store delete removes the tracked object and is idempotent" do
      store = MemoryChunkStore.new
      store.put!(1, "deadbeef", "bytes")
      assert store.exists?(1, "deadbeef")

      store.delete(1, "deadbeef")
      assert_not store.exists?(1, "deadbeef")

      # Idempotent: deleting an absent object must not raise.
      assert_nothing_raised { store.delete(1, "deadbeef") }
    end

    test "key_for isolates per user" do
      store = MemoryChunkStore.new
      assert_equal "chunks/7/abc", store.key_for(7, "abc")
    end
  end
end
