require "test_helper"

# The scheduled retention job applies the configured policy across every user, then
# sweeps freed chunks. It DELEGATES to Sync::Gc.apply_retention! (the tested mechanism) —
# it must not reimplement pruning. Default policy is keep_all, so by default it prunes
# nothing (self-host safe); managed sets RETENTION_POLICY=tiered.
class RetentionJobTest < ActiveSupport::TestCase
  setup do
    Storage::ChunkStore.reset!
    @user = User.create!(email: "rj@example.com")
  end

  # Give a user a node with two same-old-day versions (one thinnable) + a current one.
  def thinnable_history!(user)
    nid = SecureRandom.uuid
    old1 = user.versions.create!(version_id: SecureRandom.uuid, node_id: nid,
                                 manifest_id: SecureRandom.hex(8), size: 1, created_at: 100.days.ago)
    user.versions.create!(version_id: SecureRandom.uuid, node_id: nid,
                          manifest_id: SecureRandom.hex(8), size: 1, created_at: 100.days.ago - 1.hour)
    cur = user.versions.create!(version_id: SecureRandom.uuid, node_id: nid,
                                manifest_id: SecureRandom.hex(8), size: 1, created_at: 1.minute.ago)
    user.nodes.create!(node_id: nid, name: "f", kind: "file", current_version_id: cur.version_id)
    [ nid, old1, cur ]
  end

  test "iterates every user (tiered policy prunes thinnable history for each)" do
    other = User.create!(email: "rj2@example.com")
    n1, = thinnable_history!(@user)
    n2, = thinnable_history!(other)

    ENV["RETENTION_POLICY"] = "tiered"
    RetentionJob.perform_now(grace: 0)

    # Each user's same-old-day pair was thinned to one survivor (+ current) → 2 versions.
    assert_equal 2, @user.versions.where(node_id: n1).count, "user 1 history thinned"
    assert_equal 2, other.versions.where(node_id: n2).count, "user 2 history thinned"
  ensure
    ENV.delete("RETENTION_POLICY")
  end

  test "default policy prunes nothing (keep_all) — end to end" do
    nid = SecureRandom.uuid
    v1 = @user.versions.create!(version_id: SecureRandom.uuid, node_id: nid,
                                manifest_id: SecureRandom.hex(8), size: 1, created_at: 400.days.ago)
    v2 = @user.versions.create!(version_id: SecureRandom.uuid, node_id: nid,
                                manifest_id: SecureRandom.hex(8), size: 1, created_at: 1.minute.ago)
    @user.nodes.create!(node_id: nid, name: "f", kind: "file", current_version_id: v2.version_id)

    assert_no_difference -> { @user.versions.count } do
      RetentionJob.perform_now
    end
  end
end
