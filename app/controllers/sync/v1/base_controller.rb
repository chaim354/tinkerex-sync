module Sync
  module V1
    # THE V1::BaseController SPLIT (Stage 3b Phase B Task 7's hardest decision -- see the PR/task
    # report for the full argument; this comment states the conclusion and the one loose end).
    #
    # Before this task, ONE class -- app/controllers/v1/base_controller.rb -- was inherited by
    # BOTH the twelve sync controllers moving into this engine AND the fourteen v1/maker/*
    # controllers staying in the host. Its contents, after Stage 3a Task 5 stripped its
    # Sync::/Storage:: references, were: `include Authentication`, `include LibraryCapabilities`,
    # and five generic JSON rescue_froms. Three ways to split it were on the table:
    #
    #   1. Host keeps V1::BaseController; this engine's controllers inherit from it.
    #   2. This engine ships a base; the host's V1::BaseController inherits from THAT.
    #   3. Both inherit from something smaller still.
    #
    # (2), IMPLEMENTED HERE. (1) was rejected outright: it makes `Sync::V1::ChangesController`
    # unloadable without a host-defined `V1::BaseController` present, the wrong direction for a
    # gem this arc's goal 1 is "a sellable, standalone engine" for (CLAUDE.md §14j, Stage 3b
    # opening decision) -- and it is a DIFFERENT failure mode than `git filter-repo`-shaped
    # relocation risk: a bare `class Foo < Bar` with `Bar` undefined fails at AUTOLOAD time, not
    # gracefully.
    #
    # `Authentication` and the five rescues are safely, unconditionally portable: `Authentication`
    # needs only `Device` (an already-declared TinkerexSync::HOST_MODELS requirement), and the
    # rescues name only ActiveRecord/ActionController stock exceptions. Both are included here (3
    # was rejected as a needless extra layer once it turned out (2)'s base only needs ONE
    # genuinely irreducible host reference -- see below -- rather than several small ones that
    # would have argued for a third, thinner shared ancestor).
    #
    # `LibraryCapabilities` is NOT portable, and finding that out was the hard part of this
    # decision. Its whole body is `FileLayer.current.capabilities...` -- FileLayer stays HOST
    # (Task 7's own instructions: its `build` case constructs Chunk, Share and S3 in one method,
    # it IS the seam), and grepping every one of the twelve controllers before moving anything
    # found NINE of them calling `require_capability!` directly in their own class bodies
    # (tree, commits, conflicts, trash, changes, nodes x2, share_links, chunks, locks), plus
    # ShareController inlining `FileLayer.current.capabilities.versioned?` outright. This is not
    # optional per-controller behaviour to strip out -- on THIS host, a share/s3 deployment hitting
    # any of these routes with no gate would try to resolve a chunk store that was never
    # configured (`STORAGE_BACKEND` defaults to `s3` outside test, no CHUNK_* set) and 500 with a
    # bare `KeyError: CHUNK_BUCKET`, the exact hole §14a's capability-gate design exists to close.
    #
    # RESOLVED FOR REAL AT STAGE 3b TASK 9 BY Sync::V1::CapabilityGate
    # (app/controllers/concerns/sync/v1/capability_gate.rb), NOT BY THE DIRECT REFERENCE THIS
    # COMMENT USED TO DEFEND. This class's own earlier draft considered exactly this shape -- "a
    # host-configurable capability_check seam (a mattr_accessor + an
    # ActiveSupport.on_load(:sync_v1_base_controller) hook)... correct in outline" -- and set it
    # aside as a new abstraction not worth building before Task 9 had a reason to. Task 9 is that
    # reason. CapabilityGate is the engine's own `require_capability!`, matching
    # LibraryCapabilities' signature and JSON shape exactly, but asking two host-configurable
    # predicates (Sync.capability_available?, Sync.capability_unavailable_message --
    # lib/tinkerex_sync/sync_module.rb) instead of FileLayer.current.capabilities directly. Both
    # default to "available, always" -- correct for a bare mount, which genuinely has every
    # capability this gate is ever asked about, by construction (see that file's own comment, not
    # a placeholder pending configuration). The host wires both, once, in
    # config/initializers/sync_capabilities.rb, to FileLayer.current.capabilities and
    # LibraryCapabilities::CAPABILITY_ABSENT -- so this app's 501 bodies stay byte-identical to
    # what direct inclusion produced; test/integration/v1/capability_gating_test.rb is unchanged
    # and still green.
    #
    # THE LOOSE END NAMED ABOVE IS NOW CLOSED FOR THIS CLASS: nothing in this file, or in
    # anything that inherits ONLY from it, names a host constant any more. NOT A CLAIM THAT ALL
    # TWELVE CONTROLLERS MOVED IN TASK 7 LOAD STANDALONE TODAY -- two of them, CommitsController
    # and ChunksController, separately `include ::V1::StashRequestBaseUrl`
    # (app/controllers/concerns/v1/stash_request_base_url.rb), a THIRD host dependency Task 9
    # found but did not close (CLAUDE.md §14j). That is a fact about those two files' own
    # `include` lines, not about this one.
    class BaseController < ActionController::API
      include Sync::V1::Authentication
      include Sync::V1::CapabilityGate

      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActionController::ParameterMissing, with: :bad_request
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable
      # A rejected-but-well-formed request (a malformed manifest hash, a move that would create
      # a cycle, a version that isn't part of the named conflict — all raise ArgumentError) is a
      # client error (422), not a server error (500). Keep the raisers narrow so this never masks
      # a genuine bug.
      rescue_from ArgumentError, with: :unprocessable
      rescue_from ActiveRecord::RecordNotUnique, with: :conflict

      private

      def not_found(_e) = render(json: { error: "not_found" }, status: :not_found)
      def bad_request(e) = render(json: { error: e.message }, status: :bad_request)
      def unprocessable(e) = render(json: { error: e.message }, status: :unprocessable_entity)
      def conflict(e) = render(json: { error: e.message }, status: :conflict)
    end
  end
end
