require "test_helper"

module Sync
  # Chunk garbage collection: refcounts are decremented when a *version* is pruned, and
  # chunks that reach 0 past a grace period are swept. v1 keeps history, so this is the
  # mechanism a future retention policy drives — but the mechanism itself must be correct
  # (no freeing a still-referenced chunk, no sweeping a fresh or live one).
  class GcTest < ActiveSupport::TestCase
    setup do
      # Freeze at a fixed midday UTC so the tiered policy's calendar-day/week/month
      # buckets are deterministic — otherwise versions aged e.g. 5.days/5.days+2.hours
      # straddle a UTC midnight when the suite runs late in the day and split across two
      # daily buckets (a wall-clock-fragile test). travel_back runs automatically on teardown.
      travel_to Time.utc(2026, 6, 1, 12, 0, 0)
      Sync::Storage::ChunkStore.reset!
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

    # THE GRACE WINDOW'S ONLY REAL TEST, and the one whose absence made the window dead code.
    #
    # The sibling above ("keeps a recently-zeroed chunk") cannot fail for the reason it exists:
    # its chunk was CREATED moments earlier in the same frozen-clock test, so `updated_at` is
    # inside the window whether or not the decrement moved it. Every other sweep test hand-sets
    # `updated_at` via update_column — the comment on the first one says "bypass the updated_at
    # touch" out loud — so the suite never observed what prune_version! itself writes there.
    #
    # This is the real shape: a chunk that has existed for hours (i.e. EVERY chunk in a real
    # library) and was zeroed just now. Before Gc.touch_refcounts!, `updated_at` still held the
    # insert_all timestamp, the window compared creation age, and the sweep freed a chunk a
    # concurrent commit could still be deduping against.
    test "sweep_orphans! keeps a chunk zeroed NOW even though it was created long ago" do
      a = "a" * 64
      v1, = commit!(name: "f", node_id: SecureRandom.uuid, chunks: [ chunk(a) ])
      # Age the chunk itself — this is the state every chunk in a real library is in.
      @user.chunks.find_by(chunk_hash: a).update_column(:updated_at, 3.hours.ago)

      Sync::Gc.prune_version!(@user, v1) # zeroed NOW, so the grace window must protect it

      assert_no_difference -> { @user.chunks.count } do
        Sync::Gc.sweep_orphans!(@user, grace: 1.hour)
      end
      assert_not_nil @user.chunks.find_by(chunk_hash: a),
                     "the window must measure time since ZEROING, not since creation"
    end

    # The sweep takes no user lock, so its batch is a snapshot the bumpers race. Simulated
    # deterministically: the store's delete for whichever chunk is swept first re-references the
    # OTHER one (what a concurrent Sync::Commit#finalize does when it dedups against a row that
    # is still present — it uploads nothing and takes the refcount 0 -> 1). The second chunk is
    # already in the loaded batch by then, so only the re-assertion of `refcount: ..0` inside the
    # DELETE can save it. Order-independent on purpose: whichever goes first, the other survives.
    test "sweep_orphans! refuses to free a chunk re-referenced after its batch was read" do
      a, b = "a" * 64, "b" * 64
      v1, = commit!(name: "f", node_id: SecureRandom.uuid, chunks: [ chunk(a), chunk(b) ])
      Sync::Gc.prune_version!(@user, v1)
      @user.chunks.update_all(updated_at: 2.hours.ago) # both past the window

      user = @user
      racer = Object.new
      racer.define_singleton_method(:delete) do |_uid, hash|
        other = hash == a ? b : a
        user.chunks.where(chunk_hash: other).update_all("refcount = refcount + 1")
      end
      Sync::Storage::ChunkStore.current = racer

      Sync::Gc.sweep_orphans!(@user, grace: 1.hour)

      assert_equal 1, @user.chunks.count, "the re-referenced chunk must survive the sweep"
      assert_equal 1, @user.chunks.sole.refcount
    ensure
      Sync::Storage::ChunkStore.reset!
    end

    # prune_version! is the claim: two overlapping retention passes holding the same in-memory
    # Version must not both decrement, or a chunk SHARED with a surviving version reaches 0 while
    # live and the sweep frees it. The second call is the overlap.
    test "prune_version! decrements once even if called twice for the same version" do
      shared = "5" * 64
      v1, = commit!(name: "a", node_id: SecureRandom.uuid, chunks: [ chunk(shared) ])
      commit!(name: "b", node_id: SecureRandom.uuid, chunks: [ chunk(shared) ])
      assert_equal 2, @user.chunks.find_by(chunk_hash: shared).refcount

      assert Sync::Gc.prune_version!(@user, v1), "first call claims the version"
      assert_not Sync::Gc.prune_version!(@user, v1), "second call finds nothing to claim"

      assert_equal 1, @user.chunks.find_by(chunk_hash: shared).refcount,
                   "still held by file b — a double decrement would zero a LIVE chunk"
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
      Sync::Storage::ChunkStore.current.put!(@user.id, a, "bytes")
      assert Sync::Storage::ChunkStore.current.exists?(@user.id, a)

      Sync::Gc.prune_version!(@user, v1) # a → refcount 0
      @user.chunks.find_by(chunk_hash: a).update_column(:updated_at, 2.hours.ago)

      Sync::Gc.sweep_orphans!(@user, grace: 1.hour)

      assert_nil @user.chunks.find_by(chunk_hash: a), "row gone"
      assert_not Sync::Storage::ChunkStore.current.exists?(@user.id, a),
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
      Sync::Storage::ChunkStore.current = boom

      assert_difference -> { @user.chunks.count }, -1 do
        assert_nothing_raised { Sync::Gc.sweep_orphans!(@user, grace: 1.hour) }
      end
      assert_nil @user.chunks.find_by(chunk_hash: a)
    ensure
      Sync::Storage::ChunkStore.reset!
    end

    # ---- apply_retention! (policy → prune_version! → sweep) -------------------

    # Make N versions of one node, each with its own unique chunk, the newest current.
    # Returns the versions oldest→newest. Spaces them out by created_at age so the tiered
    # policy thins them; sets node.current_version_id to the newest.
    def make_history!(node_id:, ages:)
      versions = ages.map do |age|
        h = SecureRandom.hex(32)
        Sync::Storage::ChunkStore.current.put!(@user.id, h, "bytes")
        manifest = SecureRandom.hex(8)
        Sync::ManifestChunk.create!(user_id: @user.id, manifest_id: manifest, seq: 0,
                              chunk_hash: h, offset: 0, length: 5)
        Sync::Chunk.create!(user_id: @user.id, chunk_hash: h, size: 5, refcount: 1)
        @user.versions.create!(version_id: SecureRandom.uuid, node_id:, manifest_id: manifest,
                               size: 5, parent_version_id: nil, created_at: age.ago)
      end
      newest = versions.max_by(&:created_at)
      @user.nodes.create!(node_id:, name: "f", kind: "file", deleted: false,
                          current_version_id: newest.version_id)
      versions
    end

    test "apply_retention! with keep_all prunes nothing" do
      nid = SecureRandom.uuid
      make_history!(node_id: nid, ages: [ 1.minute, 5.days, 400.days ])
      assert_no_difference -> { @user.versions.where(node_id: nid).count } do
        Sync::Gc.apply_retention!(@user, policy: Sync::RetentionPolicy.for(mode: "keep_all"))
      end
    end

    test "apply_retention! tiered prunes thinned versions but NEVER current" do
      nid = SecureRandom.uuid
      # current (1 min), plus 3 versions on the same old day → 2 of those 3 thinned.
      vs = make_history!(node_id: nid, ages: [ 1.minute, 5.days, 5.days + 1.hour, 5.days + 2.hours ])
      current = vs.max_by(&:created_at)

      Sync::Gc.apply_retention!(@user, policy: Sync::RetentionPolicy.for(mode: "tiered"), grace: 0)

      surviving = @user.versions.where(node_id: nid).pluck(:version_id)
      assert_includes surviving, current.version_id, "current_version is never pruned"
      assert_equal 2, surviving.length, "current + one daily survivor"
    end

    test "apply_retention! tiered NEVER prunes a pinned version" do
      nid = SecureRandom.uuid
      vs = make_history!(node_id: nid, ages: [ 1.minute, 200.days, 200.days + 1.hour ])
      current = vs.max_by(&:created_at)
      pinned = vs.min_by(&:created_at)
      pinned.update!(pinned: true)

      Sync::Gc.apply_retention!(@user, policy: Sync::RetentionPolicy.for(mode: "tiered"), grace: 0)

      surviving = @user.versions.where(node_id: nid).pluck(:version_id)
      assert_includes surviving, pinned.version_id, "pinned version is never pruned"
      assert_includes surviving, current.version_id
    end

    test "apply_retention! tiered frees the chunks of pruned versions from storage" do
      nid = SecureRandom.uuid
      vs = make_history!(node_id: nid, ages: [ 1.minute, 5.days, 5.days + 1.hour ])
      # Same-day pair {5d, 5d+1h}: tiered keeps the NEWEST (5d), thins the older (5d+1h).
      pruned_candidate = vs.min_by(&:created_at) # oldest overall → the 5d+1h one
      pruned_hash = pruned_candidate.manifest_chunks.first.chunk_hash
      assert Sync::Storage::ChunkStore.current.exists?(@user.id, pruned_hash)

      Sync::Gc.apply_retention!(@user, policy: Sync::RetentionPolicy.for(mode: "tiered"), grace: 0)

      assert_nil @user.versions.find_by(version_id: pruned_candidate.version_id), "version pruned"
      assert_nil @user.chunks.find_by(chunk_hash: pruned_hash), "chunk row gone"
      assert_not Sync::Storage::ChunkStore.current.exists?(@user.id, pruned_hash),
                 "refcount-0 chunk deleted from storage"
    end

    # ---- Fix 3: retention never prunes a version an open conflict or live share link needs ----

    test "tiered retention keeps a version referenced by an unresolved conflict, and it stays resolvable" do
      nid = SecureRandom.uuid
      # A same-day pair the tiered policy would otherwise thin (keeps newest, prunes the older).
      vs = make_history!(node_id: nid, ages: [ 1.minute, 5.days, 5.days + 1.hour ])
      would_prune = vs.min_by(&:created_at) # the 5d+1h version — normally thinned
      current = vs.max_by(&:created_at)

      # Record an unresolved conflict whose INCOMING side is the would-be-pruned version.
      @user.conflicts.create!(node_id: nid, incoming_version_id: would_prune.version_id,
                              current_version_id: current.version_id)

      Sync::Gc.apply_retention!(@user, policy: Sync::RetentionPolicy.for(mode: "tiered"), grace: 0)

      assert @user.versions.find_by(version_id: would_prune.version_id),
             "a version referenced by an open conflict must not be pruned"
      assert @user.chunks.find_by(chunk_hash: would_prune.manifest_chunks.first.chunk_hash),
             "its chunks survive too (resolution needs them)"

      # And it is still resolvable afterward (keep that side).
      assert_nothing_raised do
        Sync::Conflicts.keep(user: @user, node_id: nid, version_id: would_prune.version_id)
      end
    end

    # THIS TEST IS ALSO THE STAGE 3a TASK 6 ARCHITECTURE GUARD, not merely a feature-correctness
    # check (it predates Task 6 by five weeks — 2026-07-15 — and was written for a plain product
    # bug: "Fix 3" above). Boundary design §1 names `Sync::Gc.apply_retention!` reading
    # `share_links` as the single highest-severity finding in the whole Stage 3 split: sever that
    # read and NOTHING notices at build time — no missing constant, no broken require — because
    # `user.share_links` still resolves (it's an ordinary AR association) and `apply_retention!`
    # still runs to completion. The nightly RetentionJob would just quietly start pruning versions
    # that a live share link still points at, destroying the bytes behind a URL a user already
    # sent someone. This test is the one thing standing between that refactor and production.
    #
    # MUTATION-CHECKED (2026-08-20, CLAUDE.md §15): deleting
    # `app/services/sync/gc.rb`'s `user.share_links.each { ... }` line from
    # `referenced_version_ids` turns this test — and only this test, in this file — red:
    #
    #   Failure:
    #   Sync::GcTest#test_tiered_retention_keeps_a_version_referenced_by_a_live_share_link
    #   a live share link's frozen version must not be pruned
    #
    # `keep_all` (the self-host default) would NOT exercise this: it never decrements anything, so
    # a version would survive with or without the referenced-ids union and the test would pass for
    # the wrong reason. `tiered` is used deliberately, because it is a policy that actually prunes.
    #
    # Why moving share_links into SYNC_SIDE_GLOBS (test/architecture_invariants_test.rb) closes the
    # hazard rather than merely relabeling it: `Sync::Gc`, `ShareLink` and `Sharing::Links` are now
    # all on the SAME side of the maker/engine boundary, so a future repo split (Stage 3b) that
    # extracts the engine wholesale carries this coupling with it intact. What this test guards
    # against is someone deciding, later, that share links are "really" a maker feature and moving
    # `ShareLink`/`Sharing::Links` back across the line while `Sync::Gc` stays put — this is the
    # test that must go red the moment that happens.
    test "tiered retention keeps a version referenced by a live share link" do
      nid = SecureRandom.uuid
      vs = make_history!(node_id: nid, ages: [ 1.minute, 5.days, 5.days + 1.hour ])
      shared = vs.min_by(&:created_at) # would be thinned

      @user.share_links.create!(node_id: nid, version_id: shared.version_id,
                                manifest_id: shared.manifest_id,
                                token_digest: Sync::ShareLink.digest(SecureRandom.hex(16)))

      Sync::Gc.apply_retention!(@user, policy: Sync::RetentionPolicy.for(mode: "tiered"), grace: 0)

      assert @user.versions.find_by(version_id: shared.version_id),
             "a live share link's frozen version must not be pruned"
      assert Sync::Storage::ChunkStore.current.exists?(@user.id, shared.manifest_chunks.first.chunk_hash),
             "its chunks survive (presigned GETs would otherwise dangle)"
    end
  end
end
