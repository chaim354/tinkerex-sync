require "test_helper"

module Sync
  # Concurrent-commit load test for the changelog sequence allocator (`User#next_seq!`).
  #
  # `next_seq!` is THE hot-path serialization point: every commit/mutation/restore/conflict
  # allocates the next per-user changelog `seq` under a row lock (`SELECT … FOR UPDATE` on
  # Postgres; SQLite serializes writes globally). If that lock were wrong — or defeated by a
  # STATEMENT-mode connection pooler that doesn't keep a transaction's statements on one
  # backend connection — concurrent commits could read the same `head_seq` and allocate a
  # DUPLICATE seq (lost update), or skip one. Both corrupt the changelog: duplicates break the
  # `[user_id, seq]` unique index; gaps/duplicates break clients' `seq > cursor` delta pulls.
  #
  # This test hammers `next_seq!` from many real threads (each with its own DB connection —
  # the same shape as many devices committing at once through a pooler) and asserts the
  # allocated seqs are EXACTLY 1..N: no duplicates, no gaps, no lost updates. It is the proof
  # the row lock is correct under real concurrency.
  #
  # Runs on BOTH SQLite and Postgres so CI without PG still exercises the invariant; against a
  # real (or pooled) Postgres it additionally proves the pooler is in session/transaction mode
  # (a statement-mode pooler would surface here as duplicates or unique-violation errors).
  class ConcurrentSeqTest < ActiveSupport::TestCase
    # Tunable via env so the same test doubles as a heavier soak load test in CI/manual runs:
    #   SEQ_LOAD_THREADS, SEQ_LOAD_PER_THREAD.
    THREADS    = Integer(ENV.fetch("SEQ_LOAD_THREADS", 16))
    PER_THREAD = Integer(ENV.fetch("SEQ_LOAD_PER_THREAD", 25))

    # CRITICAL: transactional fixtures wrap each test in ONE shared transaction on ONE shared
    # connection — every thread's `with_connection` would hand back that same connection, so the
    # row lock becomes a no-op against itself and we'd measure a test-harness artifact, not the
    # real allocator. We need each thread on its OWN connection committing for real (the shape of
    # many devices hitting a pooled DB), so disable transactional tests here and clean up by hand.
    self.use_transactional_tests = false

    setup do
      sweep!
      @user = User.create!(email: "seqload@example.com")
    end

    teardown do
      sweep!
    end

    # FK-safe sweep of everything these tests create (idempotent — used in both setup & teardown
    # since non-transactional tests don't auto-rollback, and a prior crashed run can leave rows).
    def sweep!
      # delete_all per table in FK-safe order avoids the version<->node current_version circular
      # FK that a naive User#destroy (which destroys versions before nulling the node pointer)
      # would trip. Order: leaf changelog/manifest/chunks, then nodes (drop the current_version
      # pointer), then versions, then devices, then the user.
      User.where(email: "seqload@example.com").find_each do |u|
        u.changelog_entries.delete_all
        Sync::ManifestChunk.where(user_id: u.id).delete_all
        u.chunks.delete_all
        u.pending_commits.delete_all
        u.nodes.update_all(current_version_id: nil)
        u.nodes.delete_all
        u.versions.delete_all
        u.devices.delete_all
        u.delete
      end
    end

    # Run `block` in `count` threads, each holding its own AR connection (mirrors many devices
    # committing concurrently through a pooler). A barrier releases all threads at once so they
    # genuinely race on the lock. Exceptions from any thread are re-raised on the main thread.
    #
    # The default test pool (5) is smaller than our thread count, so threads would otherwise
    # serialize on connection checkout — defeating the point. We widen the pool for the duration
    # so every thread holds a real, distinct connection simultaneously.
    def in_parallel(count)
      errors = Queue.new
      barrier = Concurrent::CountDownLatch.new(count)
      with_pool_size(count + 2) do
        threads = count.times.map do |i|
          Thread.new(i) do |n|
            ActiveRecord::Base.connection_pool.with_connection do
              barrier.count_down
              barrier.wait
              begin
                yield n
              rescue => e
                errors << e
              ensure
                ActiveRecord::Base.connection_handler.clear_active_connections!
              end
            end
          end
        end
        threads.each(&:join)
      end
      raise errors.pop until errors.empty?
    end

    # Temporarily resize the AR connection pool so `count` threads can each hold a connection
    # at once. AR builds the pool from db_config at boot, so we swap in a copy with a larger
    # `pool:` and restore the original afterwards.
    def with_pool_size(size)
      handler = ActiveRecord::Base.connection_handler
      original = ActiveRecord::Base.connection_pool
      cfg = original.db_config
      # SQLite's profile sets `max_connections`, Postgres sets `pool` — they're the same knob and
      # AR rejects having both. Drop max_connections and set pool so this works on either adapter.
      hash = cfg.configuration_hash.except(:max_connections).merge(pool: size)
      bigger = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        cfg.env_name, cfg.name, hash
      )
      handler.establish_connection(bigger)
      yield
    ensure
      handler.establish_connection(original.db_config) if original
    end

    test "next_seq! allocates a gapless, duplicate-free 1..N under concurrency" do
      total = THREADS * PER_THREAD
      allocated = Queue.new

      in_parallel(THREADS) do
        PER_THREAD.times do
          # Each allocation must be inside a transaction — that's the contract of next_seq!
          # (the row lock must span the read+write; a statement-mode pooler that breaks the
          # transaction across connections would defeat it).
          seq = ActiveRecord::Base.transaction { @user.next_seq! }
          allocated << seq
        end
      end

      seqs = []
      seqs << allocated.pop until allocated.empty?

      assert_equal total, seqs.size, "every allocation returned a seq"
      assert_equal total, seqs.uniq.size, "NO duplicate seqs (lost update / statement-pooler symptom)"
      assert_equal (1..total).to_a, seqs.sort, "seqs are exactly 1..N — gapless, no skips"
      assert_equal total, @user.reload.head_seq, "head_seq advanced to N exactly"
    end

    test "concurrent full commits produce a gapless duplicate-free changelog" do
      # Exercises the REAL commit path (begin → finalize, which calls next_seq! inside its own
      # transaction alongside version/node/changelog writes), not just next_seq! in isolation.
      Sync::Storage::ChunkStore.reset!
      device = Device.register!(user: @user, name: "loadgen")
      total = THREADS * PER_THREAD

      in_parallel(THREADS) do |t|
        PER_THREAD.times do |k|
          cid = SecureRandom.uuid
          nid = SecureRandom.uuid
          h = Digest::SHA256.hexdigest("#{t}-#{k}-#{cid}")
          manifest = [ { "hash" => h, "offset" => 0, "length" => 1 } ]
          Sync::Commit.begin(user: @user, device:, commit_id: cid, node_id: nid,
                             parent_node_id: nil, name: "f-#{t}-#{k}.bin",
                             base_version_id: nil, size: 1, manifest:)
          Sync::Commit.finalize(user: @user, commit_id: cid)
        end
      end

      seqs = @user.changelog_entries.pluck(:seq).sort
      assert_equal total, seqs.size, "one changelog entry per commit"
      assert_equal (1..total).to_a, seqs, "changelog seqs are exactly 1..N — gapless + unique"
      assert_equal total, @user.reload.head_seq
    end
  end
end
