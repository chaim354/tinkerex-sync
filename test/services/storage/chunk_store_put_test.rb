require "test_helper"

class ChunkStorePutTest < ActiveSupport::TestCase
  test "memory store round-trips a server-side put" do
    store = Sync::Storage::MemoryChunkStore.new
    store.put(42, "abc123", "hello".b)
    assert store.exists?(42, "abc123")
    assert_equal "hello".b, store.read_blob(42, "abc123")
  end
end
