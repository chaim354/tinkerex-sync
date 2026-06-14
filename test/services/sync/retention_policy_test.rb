require "test_helper"

module Sync
  # The retention policy decides which versions to KEEP for a node. Pruning the rest is
  # the existing Sync::Gc.prune_version! mechanism — this class only computes the keep-set.
  #
  # Hard invariants (never violated by any mode):
  #   - the node's current_version is ALWAYS kept (restore-to-now must work),
  #   - any pinned version is ALWAYS kept.
  #
  # Modes: keep_all (self-host default, never prunes) and tiered (managed: Time-Machine-
  # style — all in last 24h, then dailies for a week, weeklies beyond).
  class RetentionPolicyTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "ret@example.com")
      @node_id = SecureRandom.uuid
      @now = Time.utc(2026, 6, 14, 12, 0, 0)
    end

    # Build a version row at a given age. The newest is the current one.
    def version!(age:, pinned: false, manifest: SecureRandom.hex(8))
      @user.versions.create!(
        version_id: SecureRandom.uuid, node_id: @node_id, manifest_id: manifest,
        size: 1, parent_version_id: nil, pinned:, created_at: @now - age
      )
    end

    def keep_ids(policy, current_id)
      versions = @user.versions.where(node_id: @node_id).to_a
      policy.keep_set(versions, current_version_id: current_id, now: @now).to_set
    end

    test "keep_all never prunes anything" do
      vs = [ version!(age: 1.minute), version!(age: 2.days), version!(age: 400.days) ]
      policy = RetentionPolicy.for(mode: "keep_all")
      kept = keep_ids(policy, vs.first.version_id)
      assert_equal vs.map(&:version_id).to_set, kept, "keep_all keeps every version"
    end

    test "self-host default mode is keep_all" do
      assert_instance_of RetentionPolicy::KeepAll, RetentionPolicy.default
    end

    test "tiered keeps all versions within the last 24h" do
      recent = [ version!(age: 1.minute), version!(age: 3.hours), version!(age: 23.hours) ]
      policy = RetentionPolicy.for(mode: "tiered")
      kept = keep_ids(policy, recent.first.version_id)
      assert_equal recent.map(&:version_id).to_set, kept
    end

    test "tiered thins older versions to one-per-day in the 1-30 day window" do
      current = version!(age: 1.minute)
      # Three versions on the SAME day (~5 days ago) → only one survives.
      same_day = [ version!(age: 5.days), version!(age: 5.days + 1.hour),
                   version!(age: 5.days + 2.hours) ]
      policy = RetentionPolicy.for(mode: "tiered")
      kept = keep_ids(policy, current.version_id)

      survivors = same_day.map(&:version_id).select { |id| kept.include?(id) }
      assert_equal 1, survivors.length, "exactly one version kept for that day"
      assert_includes kept, current.version_id
    end

    test "tiered ALWAYS keeps the current version even if ancient" do
      ancient_current = version!(age: 800.days)
      policy = RetentionPolicy.for(mode: "tiered")
      kept = keep_ids(policy, ancient_current.version_id)
      assert_includes kept, ancient_current.version_id,
                      "current_version is never pruned regardless of age"
    end

    test "tiered ALWAYS keeps a pinned version even if it would otherwise be thinned" do
      current = version!(age: 1.minute)
      # Two versions same old day; pin one — both the daily survivor AND the pin survive,
      # but crucially the pinned one is guaranteed in the keep-set.
      pinned_old = version!(age: 200.days, pinned: true)
      version!(age: 200.days + 1.hour) # same-day sibling, unpinned

      policy = RetentionPolicy.for(mode: "tiered")
      kept = keep_ids(policy, current.version_id)
      assert_includes kept, pinned_old.version_id, "pinned version is never pruned"
    end
  end
end
