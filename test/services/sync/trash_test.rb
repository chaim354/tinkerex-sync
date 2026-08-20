require "test_helper"

module Sync
  # Trash.list surfaces tombstoned nodes; Trash.restore un-tombstones a node and
  # re-points it at its EXISTING current version (no new chunks — keep-versions
  # invariant) while appending exactly one changelog entry so devices converge.
  class TrashTest < ActiveSupport::TestCase
    setup do
      Sync::Storage::ChunkStore.reset!
      @user = User.create!(email: "trash@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    def commit!(node_id: SecureRandom.uuid, parent: nil, name: "f.bin", hash: "1" * 64, len: 5)
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id:,
                         parent_node_id: parent, name:, base_version_id: nil,
                         size: len, manifest: [ { "hash" => hash, "offset" => 0, "length" => len } ])
      v, = Sync::Commit.finalize(user: @user, commit_id: cid)
      [ node_id, v ]
    end

    def delete!(node_id)
      node = @user.nodes.find_by(node_id:)
      Sync::Mutation.apply(user: @user, node:, op: "delete") { |n| n.deleted = true }
    end

    test "list returns only tombstoned nodes" do
      kept, = commit!(name: "keep.bin")
      gone, = commit!(name: "gone.bin", hash: "2" * 64)
      delete!(gone)

      ids = Sync::Trash.list(user: @user).map(&:node_id)
      assert_includes ids, gone
      assert_not_includes ids, kept
    end

    test "restore un-tombstones and re-points at the existing current version" do
      node_id, v = commit!
      delete!(node_id)
      assert @user.nodes.find_by(node_id:).deleted

      restored, seq = Sync::Trash.restore(user: @user, node_id:)
      node = @user.nodes.find_by(node_id:)
      assert_not node.deleted, "node is back"
      assert_equal v.version_id, node.current_version_id, "re-points at the kept version"
      assert_equal node_id, restored.node_id
      assert_equal seq, @user.reload.head_seq
    end

    test "restore appends exactly one changelog entry (op put) so devices converge" do
      node_id, = commit!
      delete!(node_id)
      before = @user.changelog_entries.count

      _, seq = Sync::Trash.restore(user: @user, node_id:)
      assert_equal before + 1, @user.changelog_entries.count
      entry = @user.changelog_entries.order(:seq).last
      assert_equal "put", entry.op
      assert_equal node_id, entry.node_id
      assert_equal seq, entry.seq
    end

    test "restore needs NO new chunks (keep-versions invariant)" do
      node_id, = commit!(hash: "a" * 64)
      delete!(node_id)
      chunks_before = @user.chunks.count
      versions_before = @user.versions.count
      refcount_before = @user.chunks.find_by(chunk_hash: "a" * 64).refcount

      Sync::Trash.restore(user: @user, node_id:)

      assert_equal chunks_before, @user.chunks.count, "no new chunks created"
      assert_equal versions_before, @user.versions.count, "no new version created (re-points existing)"
      assert_equal refcount_before, @user.chunks.find_by(chunk_hash: "a" * 64).refcount,
                   "refcount unchanged — the version already references the chunk"
    end

    test "restoring a non-deleted node is a no-op (no changelog entry)" do
      node_id, = commit!
      before = @user.changelog_entries.count
      _, seq = Sync::Trash.restore(user: @user, node_id:)
      assert_nil seq
      assert_equal before, @user.changelog_entries.count
    end

    test "restore raises when the parent is deleted unless to_root" do
      dir_id = SecureRandom.uuid
      Sync::Mutation.apply(
        user: @user,
        node: @user.nodes.create!(node_id: dir_id, name: "Projects", kind: "dir", deleted: false),
        op: "mkdir"
      )
      child, = commit!(parent: dir_id, name: "part.stl")
      delete!(child)
      delete!(dir_id)

      assert_raises(Sync::Trash::ParentDeleted) do
        Sync::Trash.restore(user: @user, node_id: child)
      end

      restored, = Sync::Trash.restore(user: @user, node_id: child, to_root: true)
      assert_not restored.deleted
      assert_nil restored.parent_node_id, "restored to root since parent is gone"
    end

    test "restoring an unknown node raises" do
      assert_raises(ActiveRecord::RecordNotFound) do
        Sync::Trash.restore(user: @user, node_id: SecureRandom.uuid)
      end
    end
  end
end
