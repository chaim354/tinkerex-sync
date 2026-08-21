require "test_helper"

module V1
  # Stage 3a Task 4's third mutation check: Sync::Hooks.commit_finalized must fire AFTER
  # Sync::Commit.finalize's transaction has committed, never from inside it (Sync::Hooks' property
  # 1; CLAUDE.md §14e's `enqueue_after_transaction_commit` finding is the precedent for why this
  # matters -- a job enqueued from inside an open transaction races the in-Puma Solid Queue worker
  # over a connection that cannot see the uncommitted row yet, and can be discarded SILENTLY).
  #
  # This is the property most likely to be undone by a later, well-meaning refactor -- "wrap the
  # hook publish in the same transaction as the write, for atomicity" reads as an improvement --
  # which is exactly why the Stage 3a plan asks for a test that catches it rather than trusting the
  # comment in the controller.
  #
  # WHY THIS FILE DISABLES TRANSACTIONAL TESTS, ALONE, RATHER THAN JOINING
  # commit_finalize_hook_test.rb. The property under test is "is a real database transaction open
  # right now", and Rails' default `use_transactional_tests` wraps EVERY test in one already -- so
  # `ApplicationRecord.connection.transaction_open?` would read `true` for the ENTIRE test
  # regardless of what the code under test does, before Sync::Commit.finalize is ever called.
  # Probed directly rather than assumed (`bin/rails runner`, RAILS_ENV=test):
  #
  #   baseline (no transaction):                          open_transactions == 0
  #   ApplicationRecord.transaction { outer }:             open_transactions == 1
  #   ApplicationRecord.transaction { nested, no requires_new }: open_transactions == 1 (SAME)
  #
  # A nested `transaction do…end` without `requires_new: true` JOINS the ambient one rather than
  # pushing a second frame `open_transactions`/`transaction_open?` can see -- so inside a normal,
  # transactionally-wrapped test, a subscriber cannot tell "Sync::Commit.finalize's transaction is
  # still open" from "the test's own wrapper transaction is open", because both read identically.
  # Only with NO ambient transaction does a real, would-be-outermost `transaction do…end` register
  # as a change at all. test/services/sync/concurrent_seq_test.rb hit the identical need for a
  # different reason (each thread needs its OWN real connection) and is the precedent for the fix:
  # disable `use_transactional_tests` and clean up by hand in teardown.
  class CommitFinalizeTransactionBoundaryTest < ActionDispatch::IntegrationTest
    self.use_transactional_tests = false

    # `pin_file_layer_backend("chunk")` DROPPED WHEN THIS TEST MOVED HERE -- see
    # tenant_isolation_test.rb's setup for the full argument.
    setup do
      Sync::Storage::ChunkStore.reset!
      @email = "txn-boundary-#{SecureRandom.hex(4)}@example.com"
    end

    teardown do
      sweep!
    end

    # FK-safe cleanup, same order as ConcurrentSeqTest#sweep! and for the same reason --
    # non-transactional tests do not auto-rollback, so this test must remove exactly what it
    # created. Idempotent (used in teardown only here, but written to tolerate a re-run after a
    # crashed prior run, same as its precedent).
    def sweep!
      User.where(email: @email).find_each do |u|
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

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    def commit_file(token, name:, node_id: SecureRandom.uuid, hash: SecureRandom.hex(32))
      cid = SecureRandom.uuid
      post "/v1/commit",
           params: { commit_id: cid, node_id:, parent_node_id: nil, name:, base_version_id: nil,
                     size: 5, manifest: [ { hash:, offset: 0, length: 5 } ] },
           as: :json, headers: auth(token)
      assert_response :success
      (JSON.parse(response.body)["put_urls"] || {}).each_value do |url|
        put url, params: "x", headers: { "CONTENT_TYPE" => "application/octet-stream" }
      end
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :success
    end

    test "the commit-finalized hook fires with no database transaction open" do
      token = bootstrap_token(email: @email, device_name: "probe")

      pin_sync_hooks_subscribers do
        fired = false
        open_during_hook = nil
        Sync::Hooks.on_commit_finalized do |**|
          fired = true
          open_during_hook = ApplicationRecord.connection.transaction_open?
        end

        commit_file(token, name: "probe.stl")

        assert fired, "the hook never fired at all -- commit_file's node lookup must have missed"
        assert_equal false, open_during_hook,
                     "Sync::Hooks.commit_finalized fired while a database transaction was still " \
                     "open -- Sync::Hooks' property 1 is violated. If this is red because the " \
                     "publish call moved inside Sync::Commit.finalize's transaction (or got " \
                     "wrapped in a new one at the call site), move it back to after " \
                     "Sync::Commit.finalize returns."
      end
    end
  end
end
