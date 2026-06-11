require "test_helper"

module Sync
  class CommitTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "svc@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    def commit!(name:, node_id:, chunks:, base: nil)
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id:,
                         parent_node_id: nil, name:, base_version_id: base,
                         size: chunks.sum { |c| c["length"] }, manifest: chunks)
      Sync::Commit.finalize(user: @user, commit_id: cid)
    end

    test "commit creates node, version, manifest, changelog and bumps head_seq" do
      chunks = [{ "hash" => "a" * 64, "offset" => 0, "length" => 10 },
                { "hash" => "b" * 64, "offset" => 10, "length" => 20 }]
      nid = SecureRandom.uuid
      version, seq = commit!(name: "f.bin", node_id: nid, chunks:)

      assert_equal 1, seq
      assert_equal 1, @user.reload.head_seq
      node = @user.nodes.find_by(node_id: nid)
      assert_equal version.version_id, node.current_version_id
      assert_equal 2, version.manifest_chunks.count
      assert_equal 1, @user.changelog_entries.count
      assert_equal "put", @user.changelog_entries.first.op
    end

    test "refcounts: shared chunk increments, new chunk starts at 1" do
      x, y, z = "x" * 64, "y" * 64, "z" * 64
      commit!(name: "a", node_id: SecureRandom.uuid,
              chunks: [{ "hash" => x, "offset" => 0, "length" => 5 }, { "hash" => y, "offset" => 5, "length" => 5 }])
      commit!(name: "b", node_id: SecureRandom.uuid,
              chunks: [{ "hash" => y, "offset" => 0, "length" => 5 }, { "hash" => z, "offset" => 5, "length" => 5 }])

      assert_equal 1, @user.chunks.find_by(chunk_hash: x).refcount
      assert_equal 2, @user.chunks.find_by(chunk_hash: y).refcount, "y referenced by both files"
      assert_equal 1, @user.chunks.find_by(chunk_hash: z).refcount
    end

    test "identical content dedups the manifest (same manifest_id)" do
      same = [{ "hash" => "c" * 64, "offset" => 0, "length" => 9 }]
      v1, = commit!(name: "a", node_id: SecureRandom.uuid, chunks: same)
      v2, = commit!(name: "b", node_id: SecureRandom.uuid, chunks: same)
      assert_equal v1.manifest_id, v2.manifest_id
      # only one manifest stored despite two files
      assert_equal 1, ManifestChunk.where(user_id: @user.id, manifest_id: v1.manifest_id).select(:manifest_id).distinct.count
    end

    test "begin is idempotent for the same commit_id" do
      cid = SecureRandom.uuid
      args = { user: @user, device: @device, commit_id: cid, node_id: SecureRandom.uuid,
               parent_node_id: nil, name: "f", base_version_id: nil, size: 5,
               manifest: [{ "hash" => "d" * 64, "offset" => 0, "length" => 5 }] }
      Sync::Commit.begin(**args)
      Sync::Commit.begin(**args)
      assert_equal 1, @user.pending_commits.where(commit_id: cid).count
    end

    test "next_seq! is monotonic across commits" do
      3.times { |i| commit!(name: "f#{i}", node_id: SecureRandom.uuid, chunks: [{ "hash" => (i.to_s * 64)[0, 64], "offset" => 0, "length" => 1 }]) }
      assert_equal [1, 2, 3], @user.changelog_entries.order(:seq).pluck(:seq)
    end
  end
end
