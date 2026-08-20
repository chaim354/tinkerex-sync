require "test_helper"

module Sync
  # G4 — the orphaned-chunk reaper.
  #
  # The orphan the existing Sync::Gc.sweep_orphans! CANNOT see: a commit uploads chunk
  # bytes to object storage via presigned PUT, then never finalizes (client crash between
  # PUT and finalize, or a finalize that raises). Those bytes sit in storage with NO DB row
  # (no `chunks` record, no `manifest_chunks`), so the refcount-walking sweep never finds
  # them. On R2 they cost money forever. The reaper enumerates the storage keyspace and
  # deletes keys that (a) have no committed `chunks` row, (b) are not referenced by any
  # in-flight `pending_commits`, and (c) are older than a grace window longer than the
  # longest plausible commit lifetime — so a live upload mid-commit is never reaped.
  class ChunkReaperTest < ActiveSupport::TestCase
    setup do
      travel_to Time.utc(2026, 6, 1, 12, 0, 0)
      Sync::Storage::ChunkStore.reset!
      @store = Sync::Storage::ChunkStore.current
      # The memory store persists its on-disk dir across tests (reset! only nils the
      # instance). The reaper enumerates that whole keyspace, so wipe it for a clean,
      # isolated keyspace per test.
      FileUtils.rm_rf(@store.root)
      FileUtils.mkdir_p(@store.root)
      @user = User.create!(email: "reaper@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    def hex = SecureRandom.hex(32)

    # Simulate a client uploading a chunk's bytes to storage, with a settable age so we can
    # place it inside or outside the grace window.
    def upload!(hash, age: 2.hours)
      @store.put!(@user.id, hash, "bytes")
      @store.set_mtime!(@user.id, hash, age.ago)
      hash
    end

    # A fully committed file → a real `chunks` row + bytes in storage.
    def commit!(name:, chunks:)
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id: SecureRandom.uuid,
                         parent_node_id: nil, name:, base_version_id: nil,
                         size: chunks.sum { |c| c["length"] }, manifest: chunks)
      chunks.each { |c| @store.put!(@user.id, c["hash"], "bytes") }
      Sync::Commit.finalize(user: @user, commit_id: cid)
    end

    def chunk(h, len = 5) = { "hash" => h, "offset" => 0, "length" => len }

    # ---- the core leak: an abandoned-upload orphan gets reaped --------------------

    test "reaps a leaked object that has no DB row and is past the grace window" do
      orphan = upload!(hex, age: 2.hours)
      assert @store.exists?(@user.id, orphan)

      reaped = Sync::ChunkReaper.reap!(@user, grace: 1.hour)

      assert_includes reaped, orphan
      assert_not @store.exists?(@user.id, orphan), "leaked object deleted from storage"
    end

    # ---- never reap a live committed chunk ---------------------------------------

    test "never reaps an object backed by a committed chunks row" do
      a = hex
      commit!(name: "f", chunks: [ chunk(a) ])
      # Age it well past the window — the DB row, not age, is what protects it.
      @store.set_mtime!(@user.id, a, 2.hours.ago)
      assert @store.exists?(@user.id, a)

      reaped = Sync::ChunkReaper.reap!(@user, grace: 1.hour)

      assert_not_includes reaped, a
      assert @store.exists?(@user.id, a), "committed chunk never touched"
      assert_not_nil @user.chunks.find_by(chunk_hash: a)
    end

    # ---- never reap an in-flight commit's object, even past the age window --------

    test "never reaps an object referenced by an in-flight pending_commit" do
      # A pending commit references this hash but its bytes were uploaded long ago (e.g. a
      # slow multi-chunk upload, or a retried begin). The pending row protects it
      # regardless of object age — it is about to be finalized.
      inflight = hex
      Sync::Commit.begin(user: @user, device: @device, commit_id: SecureRandom.uuid,
                         node_id: SecureRandom.uuid, parent_node_id: nil, name: "p",
                         base_version_id: nil, size: 5, manifest: [ chunk(inflight) ])
      upload!(inflight, age: 5.hours) # old object, but a live pending references it

      reaped = Sync::ChunkReaper.reap!(@user, grace: 1.hour)

      assert_not_includes reaped, inflight
      assert @store.exists?(@user.id, inflight), "in-flight commit's object never reaped"
    end

    # ---- grace window: a freshly-uploaded orphan is left alone -------------------

    test "does not reap an orphan younger than the grace window" do
      fresh = upload!(hex, age: 10.minutes) # no DB row, but recent → maybe mid-commit

      reaped = Sync::ChunkReaper.reap!(@user, grace: 1.hour)

      assert_not_includes reaped, fresh
      assert @store.exists?(@user.id, fresh), "young orphan retained (could be in-flight)"
    end

    # ---- dry-run reports but deletes nothing -------------------------------------

    test "dry_run reports what it would reap but deletes nothing" do
      orphan = upload!(hex, age: 2.hours)

      would = Sync::ChunkReaper.reap!(@user, grace: 1.hour, dry_run: true)

      assert_includes would, orphan
      assert @store.exists?(@user.id, orphan), "dry-run must not delete"
    end

    # ---- idempotent: a second run is a clean no-op -------------------------------

    test "is idempotent — a re-run after a reap finds nothing" do
      upload!(hex, age: 2.hours)
      first = Sync::ChunkReaper.reap!(@user, grace: 1.hour)
      assert_equal 1, first.length

      second = Sync::ChunkReaper.reap!(@user, grace: 1.hour)
      assert_empty second, "nothing left to reap"
    end

    # ---- per-user scoping: never crosses tenants ---------------------------------

    test "is scoped per user — never reaps another user's leaked object" do
      other = User.create!(email: "other@example.com")
      other_orphan = hex
      @store.put!(other.id, other_orphan, "bytes")
      @store.set_mtime!(other.id, other_orphan, 2.hours.ago)

      reaped = Sync::ChunkReaper.reap!(@user, grace: 1.hour)

      assert_not_includes reaped, other_orphan
      assert @store.exists?(other.id, other_orphan), "other user's object untouched"
    end

    # ---- the all-users entry point ----------------------------------------------

    test "reap_all! sweeps every user and returns a per-user count" do
      upload!(hex, age: 2.hours)
      u2 = User.create!(email: "u2@example.com")
      o2 = hex
      @store.put!(u2.id, o2, "bytes")
      @store.set_mtime!(u2.id, o2, 2.hours.ago)

      total = Sync::ChunkReaper.reap_all!(grace: 1.hour)

      assert_equal 2, total, "one orphan reaped per user"
    end
  end
end
