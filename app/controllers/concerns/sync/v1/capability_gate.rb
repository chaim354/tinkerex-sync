# THE ENGINE'S OWN `require_capability!` — what `Sync::V1::BaseController` includes now, in place
# of the host's `::LibraryCapabilities` (Stage 3b Task 9; CLAUDE.md §14j names this one of "two
# host dependencies... a bare mount cannot load today"; see `Sync::V1::BaseController`'s own
# header for the fuller history of the split this completes).
#
# NAMESPACED `Sync::V1::`, NOT BARE `Sync::`, MATCHING `Sync::V1::Authentication`'S OWN
# REASONING, NOT THE LITERAL EXAMPLE PATH THE TASK NAMED — the render-a-501 MECHANISM here (a
# `before_action`, a specific JSON error shape, the `:not_implemented` status) is v1-wire-format
# infrastructure exactly the way a `Bearer` header and a JSON 401 body are for `Authentication`:
# if this engine ever grows a v2 wire format, that version should not automatically inherit
# either one's conventions. The QUESTION this concern answers — "is `capability` available in
# THIS deployment" — is genuinely version-agnostic, which is why it lives one level up, as a bare
# `Sync.capability_available?` (`lib/tinkerex_sync/sync_module.rb`), not on this module. Contrast
# the host's `::LibraryCapabilities`: it serves BOTH the v1 API and the session-authed web layer
# from one shared concern, because the host has both. This engine has only the former — every
# controller here is `< ActionController::API` — so nothing today distinguishes the two
# placements functionally; this one is chosen for consistency with the sibling concern already
# doing the identical reasoning, not because a difference has been observed yet.
#
# SAME SIGNATURE, SAME JSON SHAPE, SAME STATUS AS `LibraryCapabilities`' OWN — deliberately, so
# swapping `Sync::V1::BaseController`'s one `include` line is the ENTIRE change any of the nine
# engine controllers that call `require_capability! :syncable` / `:versioned` needs. None of them
# names this module, `LibraryCapabilities`, or `FileLayer` directly, and none should ever have
# to. `only:` is forwarded to `before_action` unexamined — `NodesController` relies on exactly
# that to scope `:versioned` to `versions`/`restore` and `:syncable` to the rest.
#
# THE 501 IS STILL A CHECK BEFORE THE CALL, NEVER A RESCUE, AND THE ARGUMENT DOES NOT MOVE:
# `NotImplementedError` is a `ScriptError` a bare `rescue` cannot catch, so a rescue-shaped gate
# would not merely have a gap — it would not work at all, and would fail to exactly the 500 this
# exists to prevent. See `app/controllers/concerns/library_capabilities.rb`'s header for the full
# three-part argument; it is unchanged by this file existing, because nothing here touches
# `NotImplementedError` at all — the sync controllers this gates never call `FileLayer`.
#
# WHAT ACTUALLY CHANGED FROM `LibraryCapabilities`, AND WHY EACH PIECE IS GONE:
#   - No `CAPABILITY_ABSENT` hash. Its English explanations ("this deployment keeps no file
#     history...") are HOST vocabulary describing HOST backends (share, s3) this engine does not
#     know exist. `Sync.capability_unavailable_message(capability)` asks the host for that
#     sentence instead of hardcoding one; the standalone default is deliberately generic (see
#     `sync_module.rb`'s own comment) because a bare mount has no backend-specific story to tell.
#   - No `helper_method :capabilities`. Every controller in this engine is JSON-only — nothing
#     here ever renders an `.erb` that could call a view helper. The host's own web controllers
#     (`FilesController`, `ModelsController`, `ProjectsController`) still `include
#     LibraryCapabilities` directly for exactly that helper; this concern does not replace that
#     one, only the v1 sync gate.
#   - `Sync.capability_available?` / `Sync.capability_unavailable_message` INSTEAD OF A LOCAL
#     `capabilities` PRIVATE METHOD. `LibraryCapabilities`' version calls
#     `FileLayer.current.capabilities` — a host constant and a host factory, unreachable from a
#     bare mount. The two `Sync` module methods are the seam: a host-configurable predicate that
#     defaults to "yes, always" (see its own comment for why that default is correct, not
#     provisional, for a standalone engine).
#
# BOTH `Sync.capability_available?` AND `Sync.capability_unavailable_message` MUST BE CALLED FROM
# INSIDE THE `before_action` BLOCK BELOW, NEVER AT `require_capability!`'S OWN CALL TIME — a real
# deviation from `LibraryCapabilities` (whose `explanation = CAPABILITY_ABSENT.fetch(...)` runs
# eagerly, once, when e.g. `TrashController`'s class body executes `require_capability!
# :syncable`), and not a stylistic one. `require_capability!` runs at CLASS-DEFINITION time — for
# every controller here, that can happen during Rails' `:eager_load!` initializer, which runs
# BEFORE `:finisher_hook` (the point where `config.after_initialize` blocks fire — railties
# 8.1.3.1's own initializer ordering). The host's wiring
# (`config/initializers/sync_capabilities.rb`) is itself inside `after_initialize`, for the same
# reason `sync_hooks.rb` and `postgres_pooler_check.rb` both are: `Sync`, and the host constants
# these lambdas eventually touch, are not reliably autoloadable while initializers are still
# running. Precomputing the message at `require_capability!` time would therefore, on any
# eager-loaded boot — production, or this app's own `bin/ci` "matches production" gate — read
# `Sync.capability_message` BEFORE the host initializer ever assigns it, bake the engine's
# generic default string into the closure, and never ask again: every 501 in production would
# silently carry the wrong sentence, with every test that drives an actual HTTP request still
# green (those requests run long after boot finishes; only asserting the eager-loaded class
# body's own frozen state would catch it, and nothing does). Reading both from inside the block
# sidesteps the ordering question entirely — by the time a real request reaches here,
# `Rails.application.initialize!` has unconditionally already returned.
module Sync
  module V1
    module CapabilityGate
      extend ActiveSupport::Concern

      class_methods do
        # `hint` matches `LibraryCapabilities`' own kwarg — names the door that DOES work, where
        # one exists, for the same reason: "no" must never read as "this is off" when the truth
        # is "you want a different endpoint."
        def require_capability!(capability, hint: nil, **options)
          before_action(**options) do
            next if Sync.capability_available?(capability)
            render json: { error: [ "#{capability}_unavailable:",
                                     Sync.capability_unavailable_message(capability),
                                     hint ].compact.join(" ") },
                   status: :not_implemented
          end
        end
      end
    end
  end
end
