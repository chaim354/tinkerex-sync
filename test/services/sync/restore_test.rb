require "test_helper"

module Sync
  # Restore re-points a node at an older version's manifest by creating a NEW version
  # (lossless, version-native). It must bump the reused chunks' refcounts (so GC can't
  # later free bytes a restore depends on), undelete the node, and propagate as a normal
  # `put` in the changelog.
  class RestoreTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "restore@example.com")
      @device = Device.register!(user: @user, name: "t")
      @node_id = SecureRandom.uuid
    end

    def commit!(chunks:, base: nil, name: "f.bin")
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id: @node_id,
                         parent_node_id: nil, name:, base_version_id: base,
                         size: chunks.sum { |c| c["length"] }, manifest: chunks)
      Sync::Commit.finalize(user: @user, commit_id: cid)
    end

    def chunk(h, len = 5) = { "hash" => h, "offset" => 0, "length" => len }

    test "restore creates a new version reusing the old manifest and re-points the node" do
      old = "1" * 64
      v1, = commit!(chunks: [chunk(old)])             # version 1
      v2, = commit!(chunks: [chunk("2" * 64)], base: v1.version_id) # version 2 (current)
      assert_equal v2.version_id, @user.nodes.find_by(node_id: @node_id).current_version_id

      v3, seq = Sync::Restore.call(user: @user, node_id: @node_id, version_id: v1.version_id)

      node = @user.nodes.find_by(node_id: @node_id)
      assert_equal v3.version_id, node.current_version_id, "node now points at the restore version"
      assert_equal v1.manifest_id, v3.manifest_id, "restore reuses the old manifest (no re-upload)"
      assert_equal v2.version_id, v3.parent_version_id, "restore chains onto the prior current version"
      assert_equal "put", @user.changelog_entries.order(:seq).last.op
      assert_equal seq, @user.reload.head_seq
    end

    test "restore bumps refcounts on the reused chunks" do
      old = "1" * 64
      v1, = commit!(chunks: [chunk(old)])
      commit!(chunks: [chunk("2" * 64)], base: v1.version_id)
      assert_equal 1, @user.chunks.find_by(chunk_hash: old).refcount

      Sync::Restore.call(user: @user, node_id: @node_id, version_id: v1.version_id)
      assert_equal 2, @user.chunks.find_by(chunk_hash: old).refcount, "restore re-references old bytes"
    end

    test "restore undeletes a tombstoned node" do
      v1, = commit!(chunks: [chunk("1" * 64)])
      Sync::Mutation.apply(user: @user, node: @user.nodes.find_by(node_id: @node_id), op: "delete") { |n| n.deleted = true }
      assert @user.nodes.find_by(node_id: @node_id).deleted

      Sync::Restore.call(user: @user, node_id: @node_id, version_id: v1.version_id)
      assert_not @user.nodes.find_by(node_id: @node_id).deleted, "restore brings the node back"
    end

    test "restoring an unknown version raises" do
      commit!(chunks: [chunk("1" * 64)])
      assert_raises(ActiveRecord::RecordNotFound) do
        Sync::Restore.call(user: @user, node_id: @node_id, version_id: SecureRandom.uuid)
      end
    end
  end
end
