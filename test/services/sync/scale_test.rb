require "test_helper"

module Sync
  # G11 — scale validation for the control plane (server side).
  #
  # The two bulk serializers (`Sync::Tree` for the initial snapshot, `Sync::Changes`
  # for the delta pull) must issue a BOUNDED number of SQL queries per page — O(1) in
  # the number of nodes/entries, not O(n). A naive per-row `find_by` for the node, its
  # current version, and that version's manifest chunks is a classic N+1 that turns a
  # 1000-node page into ~2000-3000 round-trips; against a managed Postgres over the
  # network that is the difference between a snappy initial sync and a multi-second one.
  #
  # These tests are the regression backstop: they assert the query count stays a small
  # constant regardless of page size. They are also the diagnostic that originally
  # exposed the N+1 (run against the pre-fix code they fail with query counts that scale
  # with N). Adapter-agnostic — pure ActiveRecord, correct on SQLite + Postgres.
  class ScaleTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "scale@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    # Build N file nodes directly (bypassing the two-phase Commit machinery for speed —
    # we are exercising the read serializers, not the write path). Each file gets its own
    # version + a small multi-chunk manifest so the manifest fan-out is real. Returns the
    # node_ids in creation order.
    def seed_files!(count, chunks_per_file: 3)
      now = Time.current
      node_rows = []
      version_rows = []
      manifest_rows = []
      chunk_rows = []
      changelog_rows = []
      seen_manifests = {}

      count.times do |i|
        node_id    = "node-#{i}"
        version_id = "ver-#{i}"
        # Make manifests mostly distinct so we exercise the worst case (no dedup hiding
        # the fan-out), but keep chunk hashes per-file unique.
        manifest_chunks = chunks_per_file.times.map do |j|
          { "hash" => "h#{i}-#{j}".ljust(64, "0"), "offset" => j * 10, "length" => 10 }
        end
        manifest_id = Sync::Commit.manifest_id_for(manifest_chunks)

        node_rows << {
          user_id: @user.id, node_id:, parent_node_id: nil, name: "f#{i}.bin",
          kind: "file", deleted: false, current_version_id: version_id,
          mode: 0o644, mtime: i, updated_seq: i + 1, created_at: now, updated_at: now
        }
        version_rows << {
          user_id: @user.id, version_id:, node_id:, manifest_id:,
          size: chunks_per_file * 10, device_id: @device.id, parent_version_id: nil,
          pinned: false, created_at: now
        }
        unless seen_manifests[manifest_id]
          seen_manifests[manifest_id] = true
          manifest_chunks.each_with_index do |c, j|
            manifest_rows << { user_id: @user.id, manifest_id:, seq: j,
                               chunk_hash: c["hash"], offset: c["offset"], length: c["length"] }
            chunk_rows << { user_id: @user.id, chunk_hash: c["hash"], size: c["length"],
                            refcount: 1, created_at: now, updated_at: now }
          end
        end
        changelog_rows << { user_id: @user.id, seq: i + 1, node_id:, op: "put",
                            version_id:, created_at: now }
      end

      Node.insert_all(node_rows)
      Version.insert_all(version_rows)
      ManifestChunk.insert_all(manifest_rows) if manifest_rows.any?
      Chunk.insert_all(chunk_rows) if chunk_rows.any?
      ChangelogEntry.insert_all(changelog_rows)
      @user.update_column(:head_seq, count)
    end

    # ---- Sync::Tree (initial snapshot) ---------------------------------------

    test "Tree snapshot query count is bounded (O(pages), not O(nodes))" do
      seed_files!(200, chunks_per_file: 3)

      large = nil
      large_n = count_queries { large = Sync::Tree.call(user: @user, after_id: 0, limit: 200) }
      small_n = count_queries { Sync::Tree.call(user: @user, after_id: 0, limit: 25) }

      # Sanity: the page actually carried the manifests we are claiming to serialize cheaply.
      assert_equal 200, large[:nodes].size
      assert large[:nodes].first[:manifest].present?, "files must carry their manifest"

      assert_operator large_n, :<=, 6,
        "Tree must issue a bounded number of queries per page; got #{large_n} for 200 nodes (N+1?)"
      assert_equal small_n, large_n,
        "Tree query count must NOT grow with page size (25 nodes: #{small_n}, 200 nodes: #{large_n})"
    end

    # ---- Sync::Changes (delta pull) ------------------------------------------

    test "Changes delta query count is bounded (O(pages), not O(entries))" do
      seed_files!(200, chunks_per_file: 3)

      delta = nil
      large_n = count_queries { delta = Sync::Changes.call(user: @user, since: 0, limit: 200) }
      small_n = count_queries { Sync::Changes.call(user: @user, since: 0, limit: 25) }

      assert_equal 200, delta[:changes].size
      assert delta[:changes].first[:manifest].present?, "put entries must carry their manifest"

      assert_operator large_n, :<=, 6,
        "Changes must issue a bounded number of queries per page; got #{large_n} for 200 entries (N+1?)"
      assert_equal small_n, large_n,
        "Changes query count must NOT grow with page size (25 entries: #{small_n}, 200 entries: #{large_n})"
    end

    # ---- correctness still holds after the batch-loading rewrite -------------

    test "Tree still serializes nodes + manifests correctly at scale" do
      seed_files!(50, chunks_per_file: 2)
      page = Sync::Tree.call(user: @user, after_id: 0, limit: 1000)
      assert_equal 50, page[:nodes].size
      n = page[:nodes].find { |x| x[:node_id] == "node-7" }
      assert_equal "ver-7", n[:version_id]
      assert_equal 20, n[:size]
      assert_equal 2, n[:manifest].size
      # manifest chunks must be in seq order
      assert_equal [ 0, 10 ], n[:manifest].map { |c| c[:offset] }
    end

    test "Changes still serializes entries + manifests correctly at scale" do
      seed_files!(50, chunks_per_file: 2)
      page = Sync::Changes.call(user: @user, since: 0, limit: 1000)
      assert_equal 50, page[:changes].size
      e = page[:changes].find { |x| x[:node_id] == "node-7" }
      assert_equal "put", e[:op]
      assert_equal "node-7", e[:node][:node_id]
      assert_equal "ver-7", e[:version][:version_id]
      assert_equal 2, e[:manifest].size
      assert_equal [ 0, 10 ], e[:manifest].map { |c| c[:offset] }
    end

    private

    # Count real SQL round-trips (excluding schema/transaction noise) issued inside the
    # block. Runs `uncached` so the AR query cache can't make a repeat measurement read
    # 0 — each call must reflect actual DB queries, so the O(pages) equality is honest.
    def count_queries(&block)
      count = 0
      counter = ->(_name, _start, _finish, _id, payload) do
        next if payload[:name] == "SCHEMA" || payload[:cached]
        sql = payload[:sql]
        next if sql.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|RELEASE|SAVEPOINT|PRAGMA)/i)
        count += 1
      end
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      end
      count
    end
  end
end
