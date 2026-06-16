require "test_helper"

module Sync
  # Targeted orphaned-chunk sweep — the cheap, common-case complement to the weekly,
  # list-based Sync::ChunkReaper (G4).
  #
  # When a `pending_commit` EXPIRES un-finalized (a client uploaded its chunk bytes via
  # presigned PUT, then crashed/abandoned before finalize), we already know EXACTLY which
  # chunk hashes it uploaded — they're in the pending row's manifest. So we can delete
  # precisely those orphaned objects directly, with NO bucket `list` call (which S3/R2 bill
  # per request). The weekly Sync::ChunkReaper stays as the catch-all backstop.
  #
  # CRITICAL SAFETY: before deleting an object we apply the SAME guards G4 uses — a hash is
  # reaped ONLY when it is referenced by neither (a) a committed `chunks` row (dedup: another
  # finalized version may share the very same content-addressed chunk) nor (b) any OTHER
  # still-live pending_commit (a concurrent commit is about to finalize it). Only truly
  # orphaned hashes are deleted; then the expired pending row is destroyed.
  class PendingCommitReaperTest < ActiveSupport::TestCase
    setup do
      travel_to Time.utc(2026, 6, 1, 12, 0, 0)
      Storage::ChunkStore.reset!
      @store = Storage::ChunkStore.current
      FileUtils.rm_rf(@store.root)
      FileUtils.mkdir_p(@store.root)
      @user = User.create!(email: "pcreaper@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    def hex = SecureRandom.hex(32)
    def chunk(h, len = 5) = { "hash" => h, "offset" => 0, "length" => len }

    # Create a pending_commit (phase-1 begin) with its bytes uploaded, then backdate the
    # pending row so it is "expired" (older than the TTL) or leave it fresh.
    def pending!(chunks:, age: 0.seconds, name: "p")
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid,
                         node_id: SecureRandom.uuid, parent_node_id: nil, name:,
                         base_version_id: nil, size: chunks.sum { |c| c["length"] },
                         manifest: chunks)
      chunks.each { |c| @store.put!(@user.id, c["hash"], "bytes") }
      pc = @user.pending_commits.find_by!(commit_id: cid)
      pc.update_column(:created_at, age.ago) if age.positive?
      pc
    end

    # A fully committed file → real `chunks` rows + bytes in storage.
    def commit!(name:, chunks:)
      cid = SecureRandom.uuid
      Sync::Commit.begin(user: @user, device: @device, commit_id: cid, node_id: SecureRandom.uuid,
                         parent_node_id: nil, name:, base_version_id: nil,
                         size: chunks.sum { |c| c["length"] }, manifest: chunks)
      chunks.each { |c| @store.put!(@user.id, c["hash"], "bytes") }
      Sync::Commit.finalize(user: @user, commit_id: cid)
    end

    # ---- the core case: an expired pending's exclusively-owned chunks get reaped -----

    test "reaps the orphaned chunks of an expired pending commit and destroys the row" do
      a, b = hex, hex
      pc = pending!(chunks: [ chunk(a), chunk(b) ], age: 25.hours)
      assert @store.exists?(@user.id, a)
      assert @store.exists?(@user.id, b)

      reaped = Sync::PendingCommitReaper.reap!(@user, ttl: 24.hours)

      assert_includes reaped, a
      assert_includes reaped, b
      assert_not @store.exists?(@user.id, a), "orphan chunk deleted"
      assert_not @store.exists?(@user.id, b), "orphan chunk deleted"
      assert_nil PendingCommit.find_by(id: pc.id), "expired pending row destroyed"
    end

    # ---- dedup guard: a chunk a committed version also references is SPARED ----------

    test "spares a chunk that is also referenced by a committed version (dedup)" do
      shared = hex
      commit!(name: "live", chunks: [ chunk(shared) ])    # finalized → a chunks row owns it
      pc = pending!(chunks: [ chunk(shared) ], age: 25.hours)
      assert_not_nil @user.chunks.find_by(chunk_hash: shared)

      reaped = Sync::PendingCommitReaper.reap!(@user, ttl: 24.hours)

      assert_not_includes reaped, shared
      assert @store.exists?(@user.id, shared), "deduped committed chunk never deleted"
      assert_nil PendingCommit.find_by(id: pc.id), "expired row still destroyed"
    end

    # ---- live-pending guard: a chunk another live pending references is SPARED -------

    test "spares a chunk that another still-live pending commit references" do
      shared = hex
      expired = pending!(chunks: [ chunk(shared) ], age: 25.hours)
      _live   = pending!(chunks: [ chunk(shared) ], age: 0.seconds, name: "fresh")

      reaped = Sync::PendingCommitReaper.reap!(@user, ttl: 24.hours)

      assert_not_includes reaped, shared
      assert @store.exists?(@user.id, shared), "chunk a live pending still needs is kept"
      assert_nil PendingCommit.find_by(id: expired.id), "expired row destroyed"
    end

    # ---- a not-yet-expired pending commit is untouched ------------------------------

    test "leaves a pending commit that has not yet expired alone" do
      a = hex
      pc = pending!(chunks: [ chunk(a) ], age: 1.hour) # well within the 24h TTL

      reaped = Sync::PendingCommitReaper.reap!(@user, ttl: 24.hours)

      assert_empty reaped
      assert @store.exists?(@user.id, a), "young pending's chunk untouched"
      assert_not_nil PendingCommit.find_by(id: pc.id), "young pending row retained"
    end

    # ---- idempotent: a second run is a clean no-op ----------------------------------

    test "is idempotent — a re-run after a reap finds nothing" do
      pending!(chunks: [ chunk(hex) ], age: 25.hours)

      first = Sync::PendingCommitReaper.reap!(@user, ttl: 24.hours)
      assert_equal 1, first.length

      second = Sync::PendingCommitReaper.reap!(@user, ttl: 24.hours)
      assert_empty second, "nothing left to reap"
    end

    # ---- best-effort on a storage delete error --------------------------------------

    test "is best-effort: a storage delete error is logged and the sweep continues" do
      a, b = hex, hex
      pc = pending!(chunks: [ chunk(a), chunk(b) ], age: 25.hours)

      # Make the delete of `a` raise; `b` must still be reaped and the row still destroyed.
      raised = false
      @store.define_singleton_method(:delete) do |user_id, hash|
        if hash == a && !raised
          raised = true
          raise "boom: transient storage error"
        end
        super(user_id, hash)
      end

      reaped = Sync::PendingCommitReaper.reap!(@user, ttl: 24.hours)

      assert_not_includes reaped, a, "failed delete is not reported as reaped"
      assert_includes reaped, b, "the rest of the sweep continued"
      assert_not @store.exists?(@user.id, b)
      assert_nil PendingCommit.find_by(id: pc.id), "row still destroyed despite a storage error"
    end

    # ---- per-user scoping: never crosses tenants ------------------------------------

    test "is scoped per user — never reaps another user's chunk" do
      other = User.create!(email: "other-pc@example.com")
      odev  = Device.register!(user: other, name: "o")
      other_hash = hex
      ocid = SecureRandom.uuid
      Sync::Commit.begin(user: other, device: odev, commit_id: ocid, node_id: SecureRandom.uuid,
                         parent_node_id: nil, name: "o", base_version_id: nil, size: 5,
                         manifest: [ chunk(other_hash) ])
      @store.put!(other.id, other_hash, "bytes")
      other.pending_commits.find_by!(commit_id: ocid).update_column(:created_at, 25.hours.ago)

      reaped = Sync::PendingCommitReaper.reap!(@user, ttl: 24.hours)

      assert_not_includes reaped, other_hash
      assert @store.exists?(other.id, other_hash), "other tenant's object untouched"
    end

    # ---- the all-users entry point --------------------------------------------------

    test "reap_all! sweeps every user and returns the total reaped count" do
      pending!(chunks: [ chunk(hex) ], age: 25.hours)
      u2 = User.create!(email: "u2-pc@example.com")
      d2 = Device.register!(user: u2, name: "d2")
      h2 = hex
      cid2 = SecureRandom.uuid
      Sync::Commit.begin(user: u2, device: d2, commit_id: cid2, node_id: SecureRandom.uuid,
                         parent_node_id: nil, name: "x", base_version_id: nil, size: 5,
                         manifest: [ chunk(h2) ])
      @store.put!(u2.id, h2, "bytes")
      u2.pending_commits.find_by!(commit_id: cid2).update_column(:created_at, 25.hours.ago)

      total = Sync::PendingCommitReaper.reap_all!(ttl: 24.hours)

      assert_equal 2, total, "one orphan reaped per user"
    end
  end
end
