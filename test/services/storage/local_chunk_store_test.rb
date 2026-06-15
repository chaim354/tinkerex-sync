require "test_helper"

module Storage
  # The local (filesystem) chunk store backs the `STORAGE_BACKEND=local` self-hosted/dev data
  # plane: a REAL presigned http PUT/GET tier (the analogue of S3/R2) so two devices can move bytes
  # without an external object store. These tests cover the storage tier (write/read/exists/delete)
  # and the HMAC URL authorization (sign/verify, tamper, expiry, per-user scope, traversal guard).
  class LocalChunkStoreTest < ActiveSupport::TestCase
    setup do
      @dir = Dir.mktmpdir("local-chunk-store-test")
      @store = LocalChunkStore.new(dir: @dir, public_url: "http://example.test")
    end
    teardown { FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir) }

    HASH = "deadbeefcafe0123"

    test "write then read round-trips the exact bytes" do
      bytes = "\x00\x01\x02hello\xff".b
      @store.write(7, HASH, bytes)
      assert @store.exists?(7, HASH)
      assert_equal bytes, @store.read(7, HASH)
    end

    test "read of an absent chunk is nil; delete is idempotent" do
      assert_nil @store.read(7, HASH)
      assert_not @store.exists?(7, HASH)
      assert_nothing_raised { @store.delete(7, HASH) }   # idempotent (mirrors S3/Memory)
      @store.write(7, HASH, "x".b)
      @store.delete(7, HASH)
      assert_not @store.exists?(7, HASH)
    end

    test "per-user isolation: same hash, different users are different objects" do
      @store.write(1, HASH, "user-1".b)
      @store.write(2, HASH, "user-2".b)
      assert_equal "user-1".b, @store.read(1, HASH)
      assert_equal "user-2".b, @store.read(2, HASH)
    end

    test "path_for rejects a non-hex hash (path-traversal guard)" do
      assert_raises(ArgumentError) { @store.path_for(1, "../../etc/passwd") }
      assert_raises(ArgumentError) { @store.path_for(1, "abc/def") }
      assert_raises(ArgumentError) { @store.path_for(1, "") }
    end

    test "presigned URL has the expected shape and a valid signature" do
      url = @store.presign_put(7, HASH, expires_in: 900)
      assert_match %r{\Ahttp://example.test/v1/chunks/blob/7/#{HASH}\?exp=\d+&sig=[0-9a-f]{64}\z}, url
      exp = url[/exp=(\d+)/, 1]
      sig = url[/sig=([0-9a-f]+)/, 1]
      assert LocalChunkStore.verify(7, HASH, exp, sig), "freshly minted URL must verify"
    end

    test "verify rejects a tampered user_id, hash, or signature" do
      exp = (Time.now + 900).to_i
      sig = LocalChunkStore.sign(7, HASH, exp)
      assert LocalChunkStore.verify(7, HASH, exp, sig)
      assert_not LocalChunkStore.verify(8, HASH, exp, sig),         "user_id swap must fail (per-user scope)"
      assert_not LocalChunkStore.verify(7, "feedface0000", exp, sig), "hash swap must fail"
      assert_not LocalChunkStore.verify(7, HASH, exp, "00" * 32),    "bad sig must fail"
    end

    test "verify rejects an expired URL even with a valid signature" do
      past = (Time.now - 5).to_i
      sig = LocalChunkStore.sign(7, HASH, past)
      assert_not LocalChunkStore.verify(7, HASH, past, sig), "expired URL must be refused"
    end

    test "factory builds the local store for STORAGE_BACKEND=local" do
      Storage::ChunkStore.reset!
      ENV["STORAGE_BACKEND"] = "local"
      ENV["CHUNK_LOCAL_DIR"] = @dir
      assert_instance_of LocalChunkStore, Storage::ChunkStore.current
    ensure
      ENV.delete("STORAGE_BACKEND")
      ENV.delete("CHUNK_LOCAL_DIR")
      Storage::ChunkStore.reset!
    end
  end
end
