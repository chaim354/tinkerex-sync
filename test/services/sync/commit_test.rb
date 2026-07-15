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
      chunks = [ { "hash" => "a" * 64, "offset" => 0, "length" => 10 },
                { "hash" => "b" * 64, "offset" => 10, "length" => 20 } ]
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

    test "commit stores the file mode and tree exposes it (executable bit syncs)" do
      nid = SecureRandom.uuid
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id: nid,
                         parent_node_id: nil, name: "run.sh", base_version_id: nil, size: 5,
                         manifest: [ { "hash" => "a" * 64, "offset" => 0, "length" => 5 } ], mode: 0o755)
      Sync::Commit.finalize(user: @user, commit_id: cid)

      assert_equal 0o755, @user.nodes.find_by(node_id: nid).mode
      tn = Sync::Tree.call(user: @user, after_id: 0, limit: 100)[:nodes].find { |n| n[:node_id] == nid }
      assert_equal 0o755, tn[:mode], "the mode is in the snapshot for other devices"
    end

    test "commit stores the real mtime and tree/changes expose it (preserved, not sync time)" do
      nid = SecureRandom.uuid
      cid = SecureRandom.uuid
      # An obviously-old mtime in unix nanoseconds (2001) — proves it's stored verbatim,
      # not replaced with the commit/sync time. The bigint column must hold ~1e18 cleanly.
      mtime = 1_000_000_000 * 1_000_000_000
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id: nid,
                         parent_node_id: nil, name: "old.txt", base_version_id: nil, size: 5,
                         manifest: [ { "hash" => "a" * 64, "offset" => 0, "length" => 5 } ], mtime: mtime)
      _, seq = Sync::Commit.finalize(user: @user, commit_id: cid)

      assert_equal mtime, @user.nodes.find_by(node_id: nid).mtime, "stored verbatim (bigint nanos)"
      tn = Sync::Tree.call(user: @user, after_id: 0, limit: 100)[:nodes].find { |n| n[:node_id] == nid }
      assert_equal mtime, tn[:mtime], "the real mtime is in the snapshot for other devices"
      ch = Sync::Changes.call(user: @user, since: seq - 1, limit: 100)[:changes].find { |c| c[:node_id] == nid }
      assert_equal mtime, ch[:node][:mtime], "the real mtime rides the changelog delta too"
    end

    test "refcounts: shared chunk increments, new chunk starts at 1" do
      x, y, z = "e" * 64, "f" * 64, "1" * 64
      commit!(name: "a", node_id: SecureRandom.uuid,
              chunks: [ { "hash" => x, "offset" => 0, "length" => 5 }, { "hash" => y, "offset" => 5, "length" => 5 } ])
      commit!(name: "b", node_id: SecureRandom.uuid,
              chunks: [ { "hash" => y, "offset" => 0, "length" => 5 }, { "hash" => z, "offset" => 5, "length" => 5 } ])

      assert_equal 1, @user.chunks.find_by(chunk_hash: x).refcount
      assert_equal 2, @user.chunks.find_by(chunk_hash: y).refcount, "y referenced by both files"
      assert_equal 1, @user.chunks.find_by(chunk_hash: z).refcount
    end

    test "identical content dedups the manifest (same manifest_id)" do
      same = [ { "hash" => "c" * 64, "offset" => 0, "length" => 9 } ]
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
               manifest: [ { "hash" => "d" * 64, "offset" => 0, "length" => 5 } ] }
      Sync::Commit.begin(**args)
      Sync::Commit.begin(**args)
      assert_equal 1, @user.pending_commits.where(commit_id: cid).count
    end

    test "next_seq! is monotonic across commits" do
      3.times { |i| commit!(name: "f#{i}", node_id: SecureRandom.uuid, chunks: [ { "hash" => (i.to_s * 64)[0, 64], "offset" => 0, "length" => 1 } ]) }
      assert_equal [ 1, 2, 3 ], @user.changelog_entries.order(:seq).pluck(:seq)
    end

    # ---- Fix 1: chunk-hash format validation (security) -----------------------

    test "begin rejects a path-traversal chunk hash (would escape the per-user prefix)" do
      err = assert_raises(Sync::Commit::InvalidManifest) do
        Sync::Commit.begin(user: @user, device: @device, commit_id: SecureRandom.uuid,
                           node_id: SecureRandom.uuid, parent_node_id: nil, name: "evil.bin",
                           base_version_id: nil, size: 5,
                           manifest: [ { "hash" => "../7/deadbeef", "offset" => 0, "length" => 5 } ])
      end
      assert_match(/invalid chunk hash/, err.message)
      assert_equal 0, @user.pending_commits.count, "no pending row created for a poisoned commit"
    end

    test "begin rejects a non-64-hex junk hash" do
      assert_raises(Sync::Commit::InvalidManifest) do
        Sync::Commit.begin(user: @user, device: @device, commit_id: SecureRandom.uuid,
                           node_id: SecureRandom.uuid, parent_node_id: nil, name: "j.bin",
                           base_version_id: nil, size: 5,
                           manifest: [ { "hash" => "NOTAHASH", "offset" => 0, "length" => 5 } ])
      end
    end

    test "begin accepts a valid 64-hex hash (regression: the happy path still works)" do
      good = "a" * 64
      res = Sync::Commit.begin(user: @user, device: @device, commit_id: SecureRandom.uuid,
                               node_id: SecureRandom.uuid, parent_node_id: nil, name: "ok.bin",
                               base_version_id: nil, size: 5,
                               manifest: [ { "hash" => good, "offset" => 0, "length" => 5 } ])
      assert_includes res.missing, good
    end

    # ---- Fix 10: manifest length cap -----------------------------------------

    test "begin rejects an over-cap manifest" do
      big = (Sync::Commit::MAX_MANIFEST_CHUNKS + 1).times.map { |i|
        { "hash" => "a" * 64, "offset" => i, "length" => 1 }
      }
      assert_raises(Sync::Commit::InvalidManifest) do
        Sync::Commit.begin(user: @user, device: @device, commit_id: SecureRandom.uuid,
                           node_id: SecureRandom.uuid, parent_node_id: nil, name: "huge.bin",
                           base_version_id: nil, size: big.size, manifest: big)
      end
    end

    # ---- Fix 8: kind-change guard --------------------------------------------

    test "finalize refuses to turn an existing dir into a file (kind change)" do
      nid = SecureRandom.uuid
      dir = @user.nodes.create!(node_id: nid, name: "adir", kind: "dir", deleted: false)
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id: nid,
                         parent_node_id: nil, name: "adir", base_version_id: nil, size: 5,
                         manifest: [ { "hash" => "a" * 64, "offset" => 0, "length" => 5 } ])
      assert_raises(Sync::Commit::KindConflict) do
        Sync::Commit.finalize(user: @user, commit_id: cid)
      end
      assert_equal "dir", dir.reload.kind, "the dir is untouched"
    end
  end
end
