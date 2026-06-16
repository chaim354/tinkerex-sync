require "test_helper"

module Sync
  # The initial-sync snapshot. Must paginate completely (no node dropped or duplicated
  # across page boundaries), exclude tombstoned nodes, and carry each file's manifest so
  # the client can build placeholders.
  class TreeTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "tree@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    def commit_node!(name:, chunks: [ { "hash" => SecureRandom.hex(32), "offset" => 0, "length" => 5 } ])
      node_id = SecureRandom.uuid
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id:,
                         parent_node_id: nil, name:, base_version_id: nil,
                         size: chunks.sum { |c| c["length"] }, manifest: chunks)
      Sync::Commit.finalize(user: @user, commit_id: cid)
      node_id
    end

    test "pagination covers every present node exactly once" do
      want = 5.times.map { |i| commit_node!(name: "f#{i}.bin") }.to_set

      seen = []
      after = 0
      loop do
        page = Sync::Tree.call(user: @user, after_id: after, limit: 2)
        break if page[:nodes].empty?
        assert page[:nodes].size <= 2, "respects the page limit"
        seen.concat(page[:nodes].map { |n| n[:node_id] })
        after = page[:next_after_id]
      end

      assert_equal want.size, seen.size, "no node duplicated across pages"
      assert_equal want, seen.to_set, "every present node appears"
    end

    test "tombstoned nodes are excluded from the snapshot" do
      keep = commit_node!(name: "keep.bin")
      drop = commit_node!(name: "drop.bin")
      Sync::Mutation.apply(user: @user, node: @user.nodes.find_by(node_id: drop), op: "delete") { |n| n.deleted = true }

      ids = Sync::Tree.call(user: @user, after_id: 0, limit: 100)[:nodes].map { |n| n[:node_id] }
      assert_includes ids, keep
      assert_not_includes ids, drop, "deleted node is not in the snapshot"
    end

    test "file nodes carry their manifest and size" do
      chunks = [ { "hash" => "a" * 64, "offset" => 0, "length" => 10 },
                { "hash" => "b" * 64, "offset" => 10, "length" => 20 } ]
      node_id = commit_node!(name: "part.stl", chunks:)

      node = Sync::Tree.call(user: @user, after_id: 0, limit: 100)[:nodes].find { |n| n[:node_id] == node_id }
      assert_equal 30, node[:size]
      assert_equal 2, node[:manifest].size
      assert_equal "a" * 64, node[:manifest].first[:hash]
    end

    test "symlink nodes carry their kind and base64 target in the snapshot" do
      target = "/usr/lib/libbar.dylib"
      node = @user.nodes.new(node_id: SecureRandom.uuid, name: "libbar.dylib",
                             kind: "symlink", symlink_target: target)
      Sync::Mutation.apply(user: @user, node:, op: "symlink")

      n = Sync::Tree.call(user: @user, after_id: 0, limit: 100)[:nodes].find { |x| x[:node_id] == node.node_id }
      assert_equal "symlink", n[:kind]
      assert_equal target, Base64.strict_decode64(n[:symlink_target])
    end

    test "head_seq is reported for the client's starting cursor" do
      commit_node!(name: "f.bin")
      snap = Sync::Tree.call(user: @user, after_id: 0, limit: 100)
      assert_equal @user.reload.head_seq, snap[:head_seq]
    end
  end
end
