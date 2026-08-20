module Sync
  # THE ENGINE'S ONE CALL INTO HOST BUSINESS LOGIC, INVERTED (Stage 3a Task 4; boundary design §2,
  # docs/superpowers/plans/2026-08-20-stage-3a-decouple-the-engine.md).
  #
  # V1::CommitsController#finalize used to call ::Maker::Previews::Enqueue.call and
  # ::Maker::ProjectIntakeJob.nudge DIRECTLY. That is categorically different from the engine
  # needing Node or User — it is not shared DATA, it is the engine reaching into the HOST'S OWN
  # FEATURES (a preview renderer, a project-folder filer). An engine that requires a preview
  # pipeline to exist cannot be run standalone, which is goal 1 of the whole four-stage
  # separation. So the engine declares an extension point here — a plain pub/sub list, nothing
  # ActiveSupport::Notifications-shaped, because this has exactly one event and no need for
  # string-keyed names or instrumentation payloads — and the host subscribes to it in
  # config/initializers/sync_hooks.rb.
  #
  # THREE PROPERTIES, each a decision, each mutation-checked
  # (test/services/sync/hooks_test.rb, test/integration/v1/commit_finalize_hook_test.rb,
  # test/integration/v1/commit_finalize_transaction_boundary_test.rb):
  #
  # 1. RUNS AFTER THE CALLER'S TRANSACTION COMMITS, NEVER INSIDE IT. This module does not open or
  #    know about a transaction itself — that would require every future publisher to share one
  #    idea of "the" transaction, which is more coupling than an event bus should carry. It is the
  #    CALLER's job to invoke #commit_finalized only once its own write has durably landed, exactly
  #    as V1::CommitsController#finalize already did for the two direct calls this replaces:
  #    Sync::Commit.finalize's `ApplicationRecord.transaction do…end` block closes, and the method
  #    RETURNS `[version, seq]`, before the controller does anything with this hook. CLAUDE.md
  #    §14e's `enqueue_after_transaction_commit` finding is the precedent for why the ordering
  #    matters: a job whose argument is a row id, enqueued from INSIDE an open transaction, races
  #    the in-Puma Solid Queue worker over a connection that cannot see the uncommitted row yet,
  #    and can be discarded SILENTLY by its own `discard_on RecordNotFound` (job 15583 / preview
  #    1747, CLAUDE.md §14h) — no failure, no log, just a row that never updates.
  # 2. A SUBSCRIBER THAT RAISES MUST NOT FAIL THE COMMIT. The bytes are already durably written by
  #    the time this fires (property 1) — a preview render failing is not a reason to hand the
  #    client an error for an upload that in fact succeeded. Rescue, log, move on to the next
  #    subscriber. Same posture `Library::Reconciler#enqueue_thumbnail` already takes for the
  #    identical call ("a render enqueue must NEVER fail the scan").
  # 3. A HOST THAT REGISTERS NOTHING MUST STILL WORK. `subscribers` defaults to an empty array, so
  #    `#commit_finalized` is a plain no-op with nothing registered — that is the ordinary shape of
  #    a bare sync server (goal 1), never a misconfiguration to special-case or warn about.
  module Hooks
    # Register a subscriber for the "a commit finalized" event. Called from
    # config/initializers/sync_hooks.rb (the host's own wiring) and from tests that want to
    # observe or fault-inject the event. Returns the block, though nothing needs the return value
    # today — Proc equality makes a future "unsubscribe" possible without this method changing.
    def self.on_commit_finalized(&block)
      subscribers << block
      block
    end

    # THE PUBLISH SIDE. `user:`, `node:` and `version:` are the OBJECTS, not pre-extracted fields —
    # deliberately event-shaped rather than call-shaped. Today's two subscribers between them read
    # node.name, node.parent_node_id (via ProjectIntakeJob.nudge), version.node_id and
    # version.version_id; a future subscriber wanting some other attribute of either does not need
    # this method's signature to change. Returns nil; nothing needs a value back from an event bus.
    def self.commit_finalized(user:, node:, version:)
      subscribers.each do |subscriber|
        subscriber.call(user:, node:, version:)
      rescue StandardError => e
        # LOGGED, NOT SWALLOWED SILENTLY — unlike Reconciler#enqueue_thumbnail's bare `rescue;
        # nil`, a failure here is one call in a per-commit hot path rather than one step of a
        # whole-library sweep that already reports its own summary, so there is no other place an
        # operator would learn a subscriber is broken. Still never re-raised: property 2 is that
        # this cannot fail the commit, and a `rescue` that re-raises after logging is not that.
        Rails.logger.error(
          "Sync::Hooks.commit_finalized subscriber raised for user=#{user.id} " \
          "node=#{node.node_id} version=#{version.version_id}: #{e.class}: #{e.message}"
        )
      end
      nil
    end

    # Every registered block, in registration order. Order matters for today's two subscribers —
    # see config/initializers/sync_hooks.rb — so this is an Array, not a Set.
    def self.subscribers
      @subscribers ||= []
    end

    # TEST-ONLY. Same shape as FileLayer.reset! / Storage::ChunkStore.reset! — clears every
    # registered subscriber so a test can assert "a host that registers nothing still works"
    # without permanently losing the production initializer's registration for the rest of the
    # process (Rails initializers run once at boot, not per-request, so there is nothing else to
    # re-run). A test that calls this MUST restore what it cleared, in its own teardown; this
    # method does not snapshot anything for you.
    def self.reset!
      @subscribers = []
    end
  end
end
