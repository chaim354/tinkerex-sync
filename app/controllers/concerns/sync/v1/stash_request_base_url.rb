module Sync
  module V1
    # THE CHUNK-DATA-PLANE HALF OF WHAT USED TO SIT ON V1::BaseController (Stage 3a Task 5; boundary
    # design §3; docs/superpowers/plans/2026-08-20-stage-3a-decouple-the-engine.md). V1::BaseController
    # is inherited by all fourteen v1/maker/* controllers, and this affordance exists ONLY for the
    # LOCAL (filesystem) chunk store: when no CHUNK_PUBLIC_URL is set, presigned blob URLs must point
    # back at the host the client is actually talking to (zero-config single-box). Grepped before
    # moving anything: no v1/maker/* controller, and no other v1 controller besides the two below,
    # calls Sync::Storage::ChunkStore, #presign_get or #presign_put anywhere — so leaving this on the shared
    # base class bought the other twenty-six v1 controllers nothing but a Sync::Storage:: reference (and,
    # for the fourteen maker ones, a reason the sync engine had to be loaded to parse their own base
    # class) they never used.
    #
    # INCLUDED ONLY BY THE TWO CONTROLLERS THAT PRESIGN A CHUNK URL: V1::CommitsController
    # (Sync::Commit.begin presigns PUT urls for missing chunks) and V1::ChunksController (#download
    # presigns GET urls for hydration). V1::ShareController needs the identical AFFORDANCE (the
    # `Sync::Storage::LocalChunkStore::PUBLIC_URL_OVERRIDE` write) for a THIRD, unrelated reason — the anonymous
    # share-link redeem side can mint GETs too — and STILL carries its own copy, on purpose, after
    # Stage 3a Task 6 (docs/superpowers/plans/2026-08-20-stage-3a-decouple-the-engine.md) looked at
    # folding it in. This comment used to say that fold-in was "Task 6's to fold in ... when there
    # is a natural single home for all three" — reasonable to expect before Task 6 ran, since the
    # remaining obstacle looked like directory placement (share_links WAS still maker-shaped then).
    # It wasn't the real obstacle: this concern's GATE below is hardcoded to `syncable?`, and
    # V1::ShareController's gate is `versioned?`, for a reason that stays true regardless of which
    # side of the boundary share_links lives on (a link needs a `versions` row, not a chunk data
    # plane). The two capabilities agree on every backend this app has today, which CLAUDE.md §14a
    # spends real space warning is three samples, not an identity — reusing this concern as-is
    # would silently swap ShareController's stated reason for this one's. See
    # V1::ShareController#stash_request_base_url for the full argument; it is intentionally NOT
    # `include V1::StashRequestBaseUrl`.
    module StashRequestBaseUrl
      extend ActiveSupport::Concern

      included do
        before_action :stash_request_base_url
      end

      private

      # GATED ON `syncable`, AND WITHOUT THE GATE A SHARE/S3 DEPLOYMENT HITTING ONE OF THESE TWO
      # syncable-GATED CONTROLLERS ANSWERS 500, NOT THE 501 require_capability! EXISTS TO GIVE IT.
      # `is_a?` cannot be asked without BUILDING the store, and STORAGE_BACKEND defaults to `s3`
      # outside test -> S3ChunkStore.from_env -> ENV.fetch("CHUNK_BUCKET") -> KeyError. A share
      # operator sets LIBRARY_*, not CHUNK_*, so without this gate every request into either
      # including controller raised here, before its own require_capability! before_action ever got
      # a chance to run and answer 501 — CLAUDE.md §14a, and test/integration/v1/capability_gating_test.rb's
      # NoChunkStoreTest is what proves it (extended, Stage 3a Task 5, to drive a request through
      # THIS concern specifically — see its comment for why the pre-existing assertions stopped
      # doing that the moment this method left every OTHER v1 controller's before_action chain).
      #
      # The internal check is load-bearing REGARDLESS OF before_action REGISTRATION ORDER, not
      # merely because of today's ordering: `included do before_action :stash_request_base_url end`
      # runs at the point each including controller's class body calls `include`, so whether that
      # line sits above or below that controller's own `require_capability!` call, Rails still runs
      # superclass/earlier-registered filters first — and `require_capability!`'s before_action lives
      # on the SUBCLASS either way. Relying on `require_capability!` having already halted the chain
      # would silently break the moment someone reordered two lines; the gate below does not depend
      # on order at all.
      #
      # The gate is the honest guard rather than a workaround, and the reason is that this is a
      # CHUNK-DATA-PLANE affordance: it exists so LocalChunkStore can presign at the host the client
      # is talking to. `syncable` is the capability that names a deployment having a chunk data plane
      # at all, so asking a chunk store to materialize where there is none is the bug, not the
      # KeyError. Note what it does NOT hide: in chunk mode `syncable` is true, the store is built,
      # and a genuinely missing CHUNK_BUCKET still raises on the first request, exactly as loudly.
      #
      # NOT `rescue KeyError` and NOT a lazier ChunkStore: the first swallows a real chunk-mode
      # misconfiguration, and the second makes every caller pay for a store this deployment will
      # never have.
      def stash_request_base_url
      # THE ENGINE'S OWN PREDICATE, not FileLayer's -- Task 9a. This file used to read
      # `FileLayer.current.capabilities.syncable?` directly, which is the last thing that stopped a
      # bare mount loading it: FileLayer is the HOST's port and a standalone sync server has none.
      # `Sync.capability_available?` defaults to true, which is the right standalone answer (the
      # engine IS the sync engine), and the host wires it back to FileLayer in an initializer so
      # its behaviour is unchanged. Everything the comment above argues about WHY the guard exists
      # is untouched -- only who is asked.
      return unless Sync.capability_available?(:syncable)
        if Sync::Storage::ChunkStore.current.is_a?(Sync::Storage::LocalChunkStore)
          Sync::Storage::LocalChunkStore::PUBLIC_URL_OVERRIDE.value = request.base_url
        end
      end
    end
  end
end
