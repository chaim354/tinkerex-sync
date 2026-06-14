require "test_helper"

module Sync
  # The pull delta. Correctness here is what makes offline-reconnect safe: the client
  # pages by `since`/`limit` and must be able to detect when it has fallen behind a
  # pruned changelog floor (`oldest_seq`) so it can full-resync instead of silently
  # skipping the pruned entries.
  class ChangesTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "changes@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    def commit!(name:)
      node_id = SecureRandom.uuid
      cid = SecureRandom.uuid
      chunks = [ { "hash" => SecureRandom.hex(32), "offset" => 0, "length" => 5 } ]
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id:,
                         parent_node_id: nil, name:, base_version_id: nil, size: 5, manifest: chunks)
      Sync::Commit.finalize(user: @user, commit_id: cid)
      node_id
    end

    test "delta respects the limit and is ordered by seq" do
      12.times { |i| commit!(name: "f#{i}.bin") }

      page = Sync::Changes.call(user: @user, since: 0, limit: 5)
      assert_equal 5, page[:changes].size, "respects the page limit"
      assert_equal [ 1, 2, 3, 4, 5 ], page[:changes].map { |c| c[:seq] }, "ascending by seq from the cursor"
      assert_equal 12, page[:head_seq]
    end

    test "paging by the last seq covers every entry exactly once" do
      ids = 12.times.map { |i| commit!(name: "f#{i}.bin") }

      seen = []
      cursor = 0
      loop do
        page = Sync::Changes.call(user: @user, since: cursor, limit: 5)
        break if page[:changes].empty?
        seen.concat(page[:changes].map { |c| c[:node_id] })
        cursor = page[:changes].last[:seq]
      end
      assert_equal ids, seen, "client-style paging reproduces the full, ordered history"
    end

    test "oldest_seq reports the retained floor and signals a pruned gap" do
      12.times { |i| commit!(name: "f#{i}.bin") }
      assert_equal 1, Sync::Changes.call(user: @user, since: 0, limit: 100)[:oldest_seq], "nothing pruned → floor is 1"

      pruned = Sync::Gc.prune_changelog!(@user, keep_after: 4)
      assert_equal 4, pruned, "entries seq 1..4 removed"

      page = Sync::Changes.call(user: @user, since: 0, limit: 100)
      assert_equal 5, page[:oldest_seq], "floor moved up to the oldest retained seq"
      assert_operator page[:oldest_seq], :>, 0 + 1, "cursor 0 is below the floor → client must full-resync"
      assert_equal 5, page[:changes].first[:seq], "the pruned entries are gone from the delta"
      assert_equal 12, page[:head_seq], "head is unchanged by pruning"
    end

    test "prune_changelog! leaves the tree snapshot complete" do
      ids = 6.times.map { |i| commit!(name: "f#{i}.bin") }
      Sync::Gc.prune_changelog!(@user, keep_after: 6) # prune ALL history

      snap_ids = Sync::Tree.call(user: @user, after_id: 0, limit: 100)[:nodes].map { |n| n[:node_id] }
      assert_equal ids.to_set, snap_ids.to_set, "every node still reachable via the snapshot after a full prune"
      assert_equal 6, @user.reload.head_seq, "head_seq is retained even when history is gone"
    end
  end
end
