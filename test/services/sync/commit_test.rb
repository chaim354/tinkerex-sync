require "test_helper"

module Sync
  class CommitTest < ActiveSupport::TestCase
    setup do
      Sync::Storage::ChunkStore.reset!
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
      assert_equal 1, Sync::ManifestChunk.where(user_id: @user.id, manifest_id: v1.manifest_id).select(:manifest_id).distinct.count
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

    # A MANIFEST ENTRY WITH NO `hash` KEY IS THE CASE THE TWO TESTS ABOVE CANNOT REACH.
    # They send junk STRINGS ("NOTAHASH", "../7/deadbeef"), so `bad` holds a truthy value and
    # `bad.any?` fires. `normalize` synthesizes `"hash" => nil` for a missing key, which makes
    # `bad == [nil]` — and `[nil].any?` is **false**, so the guard was skipped and the nil was
    # persisted into `pending_commits.manifest_json`. Hence `unless bad.empty?` at the door.
    # THE ROW IS ASSERTED BEFORE THE RAISE, deliberately: under the `if bad.any?` mutation the
    # first thing that must go red is "a row was created", not "nothing was raised" — the row
    # is the wedge (see the reaper-side test in pending_commit_reaper_test.rb), the missing
    # raise is only how it got there.
    test "begin refuses a manifest entry with NO hash key, and persists nothing" do
      err = nil
      begin
        Sync::Commit.begin(user: @user, device: @device, commit_id: SecureRandom.uuid,
                           node_id: SecureRandom.uuid, parent_node_id: nil, name: "nohash.bin",
                           base_version_id: nil, size: 5,
                           manifest: [ { "offset" => 0, "length" => 5 } ])
      rescue Sync::Commit::InvalidManifest => e
        err = e
      end

      assert_equal [], @user.pending_commits.pluck(:manifest_json),
                   "a nil-hash manifest must never reach pending_commits — that row wedges " \
                   "Sync::PendingCommitReaper on a LocalChunkStore deployment, permanently"
      refute_nil err, "the door must raise InvalidManifest, not merely decline to persist"
      assert_match(/invalid chunk hash/, err.message)
    end

    test "begin refuses an EXPLICIT nil hash, and persists nothing" do
      err = nil
      begin
        Sync::Commit.begin(user: @user, device: @device, commit_id: SecureRandom.uuid,
                           node_id: SecureRandom.uuid, parent_node_id: nil, name: "nilhash.bin",
                           base_version_id: nil, size: 5,
                           manifest: [ { "hash" => nil, "offset" => 0, "length" => 5 } ])
      rescue Sync::Commit::InvalidManifest => e
        err = e
      end

      assert_equal [], @user.pending_commits.pluck(:manifest_json),
                   "an explicit null hash is the same [nil] `bad` set as an absent key"
      refute_nil err, "the door must raise InvalidManifest, not merely decline to persist"
      assert_match(/invalid chunk hash/, err.message)
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

    # ---- F-02: finalize's verify must not probe `chunks` one hash at a time ------
    #
    # `verify: true` is the production default (config/initializers/finalize_verification.rb
    # defaults SYNC_VERIFY_FINALIZE to "1"; FilesController#finalize_upload hard-codes it), and its
    # block asks "does this user already have this chunk?" once per manifest entry. Asked per hash
    # that is N sequential DB round-trips with DISTINCT binds, which the AR query cache cannot
    # coalesce — and the FULLY-DEDUPED re-commit, the very case the initializer describes as one the
    # "write hot path pays nothing for", is the case that pays all N: the `||` short-circuits the
    # storage HEAD, so only the DB half runs. Measured pre-fix: 5 queries at n=5, 100 at n=100.
    #
    # ASSERT CONSTANCY IN N, NEVER A LITERAL (§14e). Every other statement in finalize is O(1) in
    # manifest size (one insert_all, one refcount update_all, the version/node/changelog writes), so
    # growth here is the N+1 returning. count_queries runs `uncached` — without that the repeat
    # measurement reads a cached 0 and passes regardless.
    test "finalize's verify does not scale its query count with manifest size (dedup hit)" do
      c_small = prepare_deduped_commit!(n: 5, salt: 0)
      c_large = prepare_deduped_commit!(n: 100, salt: 1_000)
      c_off   = prepare_deduped_commit!(n: 100, salt: 2_000)

      small = count_queries { Sync::Commit.finalize(user: @user, commit_id: c_small, verify: true) }
      large = count_queries { Sync::Commit.finalize(user: @user, commit_id: c_large, verify: true) }
      off   = count_queries { Sync::Commit.finalize(user: @user, commit_id: c_off, verify: false) }

      # The guard must be able to fail for the reason it exists: flip the two measured calls to
      # `verify: false` and this line goes red, instead of the test silently measuring the
      # begin-only path and passing whether or not the N+1 is there.
      assert_operator large, :>, off,
                      "verify: true must actually run the block under measurement"
      assert_equal small, large,
                   "verify probed `chunks` per hash: #{small} queries at n=5 vs #{large} at n=100"
      assert_equal 3, @user.versions.count, "all three commits still finalized"
    end

    test "finalize's verify raises ChunksMissing with the complete missing set, in manifest order" do
      # DESCENDING ON PURPOSE. With an ascending manifest, manifest order and SORTED order coincide,
      # so a `.sort` slipped into the reject would pass and this test's own name would be a lie.
      # Probed: against an ascending fixture, `.reverse` and a Set-difference both go RED but
      # `.sort` stays GREEN. Reversing here is what gives the assertion teeth in all three
      # directions. Do not "tidy" this back to ascending.
      m = manifest_of(6, salt: 5_000).reverse
      seed_chunks!([ m[0], m[2], m[4] ])
      cid = begin_commit!(m, name: "gap.bin")

      err = assert_raises(Sync::Commit::ChunksMissing) do
        Sync::Commit.finalize(user: @user, commit_id: cid, verify: true)
      end
      # v1/commits_controller#finalize and FilesController#finalize_upload render e.hashes to the
      # client verbatim, so the ORDER is part of the response: reject from the ordered manifest
      # against the known-set, never iterate the set.
      assert_equal [ m[1], m[3], m[5] ].map { |c| c["hash"] }, err.hashes
      assert_equal 0, @user.versions.count, "no version for a commit whose bytes never landed"
    end

    private

    # n distinct valid 64-hex hashes; `salt` keeps two manifests in one test from sharing chunks.
    def manifest_of(n, salt: 0)
      n.times.map { |i| { "hash" => format("%064x", salt + i), "offset" => i * 10, "length" => 10 } }
    end

    def seed_chunks!(manifest)
      now = Time.current
      Sync::Chunk.insert_all(manifest.map { |c|
        { user_id: @user.id, chunk_hash: c["hash"], size: c["length"],
          refcount: 1, created_at: now, updated_at: now }
      })
    end

    def begin_commit!(manifest, name:)
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id: SecureRandom.uuid,
                         parent_node_id: nil, name:, base_version_id: nil,
                         size: manifest.sum { |c| c["length"] }, manifest:)
      cid
    end

    # A pending commit whose chunks the user ALREADY has rows for — the dedup-hit case, where the
    # storage HEAD never runs and the DB half is the whole cost.
    def prepare_deduped_commit!(n:, salt:)
      m = manifest_of(n, salt:)
      seed_chunks!(m)
      begin_commit!(m, name: "dedup-#{salt}.bin")
    end

    # Same shape as test/services/sync/scale_test.rb's helper: count real SQL round-trips
    # (excluding schema/transaction noise) inside the block, `uncached` so the AR query cache can't
    # make a repeat measurement read 0.
    def count_queries(&block)
      count = 0
      counter = ->(_name, _start, _finish, _id, payload) do
        next if payload[:name] == "SCHEMA" || payload[:cached]
        next if payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|RELEASE|SAVEPOINT|PRAGMA)/i)
        count += 1
      end
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      end
      count
    end
  end
end
