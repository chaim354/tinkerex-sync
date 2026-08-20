require "test_helper"

module Sync
  # Unit tests for Sync::Hooks' own contract (Stage 3a Task 4; app/services/sync/hooks.rb) --
  # registration, publish order, and the two properties that live entirely inside this module:
  # a raising subscriber must not stop a later subscriber or propagate out of #commit_finalized
  # (property 2), and an empty subscriber list is a plain no-op (property 3).
  #
  # PROPERTY 1 ("runs after the transaction commits") IS DELIBERATELY NOT HERE. It is a claim
  # about WHEN a caller invokes #commit_finalized, not about anything this module does with a
  # database connection -- Sync::Hooks itself has no idea what a transaction is. Pinned instead
  # at the controller/integration level, where a real transaction exists to observe:
  # test/integration/v1/commit_finalize_transaction_boundary_test.rb.
  #
  # DOUBLES, NOT FIXTURES OR PERSISTED RECORDS. commit_finalized only ever reads three attributes
  # off its arguments outside a subscriber's own use of them -- user.id, node.node_id,
  # version.version_id, all inside the rescue's log line -- so a plain Struct is the whole
  # contract and keeps this suite independent of any AR validation or DB round trip.
  class HooksTest < ActiveSupport::TestCase
    FakeUser = Struct.new(:id)
    FakeNode = Struct.new(:node_id, :name)
    FakeVersion = Struct.new(:node_id, :version_id)

    setup do
      @user = FakeUser.new(42)
      @node = FakeNode.new(SecureRandom.uuid, "widget.stl")
      @version = FakeVersion.new(@node.node_id, SecureRandom.uuid)
    end

    test "a registered subscriber receives user:, node: and version: by identity" do
      pin_sync_hooks_subscribers do
        received = nil
        Sync::Hooks.on_commit_finalized { |user:, node:, version:| received = { user:, node:, version: } }

        Sync::Hooks.commit_finalized(user: @user, node: @node, version: @version)

        assert_same @user, received[:user]
        assert_same @node, received[:node]
        assert_same @version, received[:version]
      end
    end

    test "subscribers run in registration order" do
      pin_sync_hooks_subscribers do
        order = []
        Sync::Hooks.on_commit_finalized { |**| order << :first }
        Sync::Hooks.on_commit_finalized { |**| order << :second }

        Sync::Hooks.commit_finalized(user: @user, node: @node, version: @version)

        assert_equal [ :first, :second ], order
      end
    end

    # PROPERTY 2, both halves: the raise does not propagate out of #commit_finalized (so a
    # caller need not rescue around it), AND it does not stop a LATER subscriber from running --
    # a per-subscriber rescue inside the `each`, not a rescue around the whole loop.
    test "a raising subscriber does not stop a later subscriber, and commit_finalized itself does not raise" do
      pin_sync_hooks_subscribers do
        ran = false
        Sync::Hooks.on_commit_finalized { |**| raise "boom" }
        Sync::Hooks.on_commit_finalized { |**| ran = true }

        assert_nothing_raised do
          Sync::Hooks.commit_finalized(user: @user, node: @node, version: @version)
        end
        assert ran, "the second subscriber must still run after the first one raised"
      end
    end

    test "with no subscribers registered, commit_finalized is a plain no-op" do
      pin_sync_hooks_subscribers do
        assert_empty Sync::Hooks.subscribers
        assert_nil Sync::Hooks.commit_finalized(user: @user, node: @node, version: @version)
      end
    end

    test "reset! clears the subscriber list" do
      # Wrapped in pin_sync_hooks_subscribers even though this test's own subject IS reset! --
      # its `ensure` restores whatever config/initializers/sync_hooks.rb actually registered at
      # boot, without this test needing to know or duplicate what that is.
      pin_sync_hooks_subscribers do
        Sync::Hooks.on_commit_finalized { |**| }
        assert_not_empty Sync::Hooks.subscribers

        Sync::Hooks.reset!

        assert_empty Sync::Hooks.subscribers
      end
    end
  end
end
