require "test_helper"

module Sync
  # Chunk garbage collection: refcounts are decremented when a *version* is pruned, and
  # chunks that reach 0 past a grace period are swept. v1 keeps history, so this is the
  # mechanism a future retention policy drives — but the mechanism itself must be correct
  # (no freeing a still-referenced chunk, no sweeping a fresh or live one).
  class GcTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "gc@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    def commit!(name:, node_id:, chunks:, base: nil)
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id:,
                         parent_node_id: nil, name:, base_version_id: base,
                         size: chunks.sum { |c| c["length"] }, manifest: chunks)
      Sync::Commit.finalize(user: @user, commit_id: cid)
    end

    def chunk(h, len = 5) = { "hash" => h, "offset" => 0, "length" => len }

    test "prune_version! decrements refcounts and destroys the version" do
      a, b = "a" * 64, "b" * 64
      v1, = commit!(name: "f", node_id: SecureRandom.uuid, chunks: [ chunk(a), chunk(b) ])
      assert_equal 1, @user.chunks.find_by(chunk_hash: a).refcount
      assert_equal 1, @user.chunks.find_by(chunk_hash: b).refcount

      Sync::Gc.prune_version!(@user, v1)

      assert_equal 0, @user.chunks.find_by(chunk_hash: a).refcount
      assert_equal 0, @user.chunks.find_by(chunk_hash: b).refcount
      assert_nil @user.versions.find_by(version_id: v1.version_id), "version destroyed"
    end

    test "prune_version! never frees a chunk still referenced by another version" do
      shared = "5" * 64
      v1, = commit!(name: "a", node_id: SecureRandom.uuid, chunks: [ chunk(shared) ])
      commit!(name: "b", node_id: SecureRandom.uuid, chunks: [ chunk(shared) ])
      assert_equal 2, @user.chunks.find_by(chunk_hash: shared).refcount

      Sync::Gc.prune_version!(@user, v1)
      assert_equal 1, @user.chunks.find_by(chunk_hash: shared).refcount, "still held by file b"
    end

    test "sweep_orphans! removes refcount-0 chunks past the grace period only" do
      a = "a" * 64
      v1, = commit!(name: "f", node_id: SecureRandom.uuid, chunks: [ chunk(a) ])
      Sync::Gc.prune_version!(@user, v1) # a → refcount 0
      # Age it past the grace window (bypass the updated_at touch).
      @user.chunks.find_by(chunk_hash: a).update_column(:updated_at, 2.hours.ago)

      assert_difference -> { @user.chunks.count }, -1 do
        Sync::Gc.sweep_orphans!(@user, grace: 1.hour)
      end
      assert_nil @user.chunks.find_by(chunk_hash: a)
    end

    test "sweep_orphans! keeps a recently-zeroed chunk (within grace)" do
      a = "a" * 64
      v1, = commit!(name: "f", node_id: SecureRandom.uuid, chunks: [ chunk(a) ])
      Sync::Gc.prune_version!(@user, v1) # refcount 0, updated just now

      assert_no_difference -> { @user.chunks.count } do
        Sync::Gc.sweep_orphans!(@user, grace: 1.hour)
      end
      assert_not_nil @user.chunks.find_by(chunk_hash: a), "inside grace → retained"
    end

    test "sweep_orphans! never removes a live (refcount>0) chunk" do
      a = "a" * 64
      commit!(name: "f", node_id: SecureRandom.uuid, chunks: [ chunk(a) ]) # refcount 1
      @user.chunks.find_by(chunk_hash: a).update_column(:updated_at, 2.hours.ago)

      assert_no_difference -> { @user.chunks.count } do
        Sync::Gc.sweep_orphans!(@user, grace: 1.hour)
      end
      assert_equal 1, @user.chunks.find_by(chunk_hash: a).refcount
    end

    test "sweep_orphans! actually deletes the refcount-0 chunk from storage" do
      a = "a" * 64
      v1, = commit!(name: "f", node_id: SecureRandom.uuid, chunks: [ chunk(a) ])
      # The client uploaded the bytes; simulate the object existing in storage.
      Storage::ChunkStore.current.put!(@user.id, a, "bytes")
      assert Storage::ChunkStore.current.exists?(@user.id, a)

      Sync::Gc.prune_version!(@user, v1) # a → refcount 0
      @user.chunks.find_by(chunk_hash: a).update_column(:updated_at, 2.hours.ago)

      Sync::Gc.sweep_orphans!(@user, grace: 1.hour)

      assert_nil @user.chunks.find_by(chunk_hash: a), "row gone"
      assert_not Storage::ChunkStore.current.exists?(@user.id, a),
                 "object deleted from storage"
    end

    test "sweep_orphans! deletes the row even if the storage delete raises (failure-safe)" do
      a = "a" * 64
      v1, = commit!(name: "f", node_id: SecureRandom.uuid, chunks: [ chunk(a) ])
      Sync::Gc.prune_version!(@user, v1)
      @user.chunks.find_by(chunk_hash: a).update_column(:updated_at, 2.hours.ago)

      # A storage that errors on delete (e.g. transient S3 outage) must not corrupt
      # refcount state: the row is removed first, the storage delete is best-effort.
      boom = Object.new
      def boom.delete(*) = raise("S3 unreachable")
      Storage::ChunkStore.current = boom

      assert_difference -> { @user.chunks.count }, -1 do
        assert_nothing_raised { Sync::Gc.sweep_orphans!(@user, grace: 1.hour) }
      end
      assert_nil @user.chunks.find_by(chunk_hash: a)
    ensure
      Storage::ChunkStore.reset!
    end
  end
end
