require "tinkerex_sync/engine"
# NOT AUTOLOADED, DELIBERATELY -- see the header of sync_module.rb for why `Sync`'s own
# module-level methods cannot live in the engine's app/ tree the way everything else here does.
require "tinkerex_sync/sync_module"

# The gem's entry point. Everything else is autoloaded by the engine out of its own app/ tree,
# exactly as the host's is -- see lib/tinkerex_sync/engine.rb for why the module is `Sync`.
module TinkerexSync
  # WHAT THE HOST MUST PROVIDE, stated in one place so a missing one fails with this list rather
  # than with `uninitialized constant`. The engine declares these as requirements and defines none
  # of them (parent design §5, CLAUDE.md §14j):
  #
  #   User   -- the tenant. Every engine table has a `user_id` FK to it, and the engine's own
  #             migration declares those FKs, so the host's `users` table must exist BEFORE the
  #             engine's migration runs. That ordering is deliberate: it fails loudly at install
  #             rather than silently at runtime, and it is what keeps `dependent: :destroy` from
  #             being the only thing standing between a deleted user and orphaned engine rows.
  #   Node   -- the catalog row. All three FileLayer backends populate it; it is the straddler.
  #   Device -- the credential. Its token is the ONLY thing the whole v1 API accepts, maker
  #             endpoints included, which is why it stays host-side rather than moving here.
  HOST_MODELS = %w[User Node Device].freeze
end
