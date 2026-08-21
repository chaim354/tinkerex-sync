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
    # RESOLVED BY MATCHING AN ALREADY-SANCTIONED PRECEDENT, NOT BY INVENTING A NEW SEAM. This
    # engine's controllers `include ::LibraryCapabilities` directly, below -- an explicit,
    # qualified reference to one host file, the identical shape
    # app/controllers/concerns/v1/stash_request_base_url.rb already has with CommitsController and
    # ChunksController (both moving in this same task), which CLAUDE.md's SYNC_SEAM_EXCEPTIONS
    # comment calls "permanent... short of the whole engine actually extracting in Phase B, at
    # which point the question of what counts as 'the maker layer' changes shape entirely" --
    # i.e. Phase A's own authors already anticipated this exact question and left it for Task 7
    # to answer, not to pre-solve. An earlier draft of this file instead built a host-configurable
    # `capability_check` seam (a mattr_accessor + an `ActiveSupport.on_load(:sync_v1_base_controller)`
    # hook, so a bare mount would default to "everything allowed" and this host would override
    # it at boot) — correct in outline, but a NEW abstraction solving a problem this codebase had
    # already decided, for `stash_request_base_url.rb`, was tolerable to leave as a direct
    # reference for now. Building a second, different-shaped answer beside an existing, argued one
    # is the inconsistency worth avoiding here, not the coupling itself.
    #
    # THE LOOSE END, NAMED RATHER THAN HIDDEN: this means `Sync::V1::BaseController` -- and by
    # inheritance, all twelve moved controllers -- cannot be loaded today without the host's
    # `LibraryCapabilities` (app/controllers/concerns/library_capabilities.rb) present. A genuinely
    # standalone mount (Task 6's test/dummy host, Task 9's engine-only suite) will need to answer
    # this for real -- likely by having the host inject its gate via config rather than this engine
    # naming the host's file directly. That is real, not-yet-done work, and it is Task 9's to do,
    # not retrofitted here under this task's own steam.
    class BaseController < ActionController::API
      include Sync::V1::Authentication
      include ::LibraryCapabilities

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
