# A GENUINE FINDING OF THIS TASK, RECORDED HERE RATHER THAN JUST IN THE TASK REPORT: the engine
# ships NO config/routes.rb of its own. Stage 3b Phase B Task 7 moved every Sync::V1::* controller
# into engines/tinkerex-sync/, but routing stayed entirely in the HOST's config/routes.rb, which
# interleaves the sync routes with two host-only routes (`devices#login`, `resources :devices`)
# and a whole `namespace :maker do ... end` block, all inside ONE `namespace :v1 do` (see that
# file's own extensive comment on why every `to:`/`controller:` needs a leading `/`). So this
# dummy app cannot simply `mount Sync::Engine` and inherit routing -- there is nothing to mount;
# routes.rb is host business, and until now no host but the real one had ever drawn them.
#
# What follows is the SYNC SUBSET of the host's namespace :v1 block, verified line-for-line
# against config/routes.rb (every path, verb and controller target copied, not re-derived) minus
# exactly the two host-only device routes and the maker namespace. It is NOT auto-generated and
# NOT shared with the host file -- the two can drift, which is the gap itself, not a decoration on
# it. If tinkerex-sync ever becomes its own repository, this is where a real
# `engines/tinkerex-sync/config/routes.rb` (drawn via `Sync::Engine.routes.draw do ... end` and
# `mount`ed by the host) belongs; today it is the dummy's own stand-in for that missing file.
Rails.application.routes.draw do
  namespace :v1 do
    # content commits (two-phase)
    post "commit", to: "/sync/v1/commits#create"
    post "commit/:commit_id/finalize", to: "/sync/v1/commits#finalize"

    # pull
    get "changes", to: "/sync/v1/changes#index"
    get "tree", to: "/sync/v1/tree#index"

    # search (name/path; scoped to the device's user)
    get "search", to: "/sync/v1/search#index"

    # metadata ops + history
    post "nodes", to: "/sync/v1/nodes#mkdir"
    post "nodes/symlink", to: "/sync/v1/nodes#symlink"
    delete "nodes/:node_id", to: "/sync/v1/nodes#destroy"
    post "nodes/:node_id/move", to: "/sync/v1/nodes#move"
    get "nodes/:node_id/versions", to: "/sync/v1/nodes#versions"
    post "nodes/:node_id/restore", to: "/sync/v1/nodes#restore"
    post "nodes/:node_id/resolve_conflict", to: "/sync/v1/nodes#resolve_conflict"

    # conflicts (offline-edit divergence)
    get "conflicts", to: "/sync/v1/conflicts#index"

    # trash / undelete (the CHUNK trash -- Sync::Trash; see TrashController's own comment)
    get "trash", to: "/sync/v1/trash#index"
    post "trash/:node_id/restore", to: "/sync/v1/trash#restore"

    # best-effort advisory edit locks
    post "nodes/:node_id/lock", to: "/sync/v1/nodes#lock"
    post "nodes/:node_id/unlock", to: "/sync/v1/nodes#unlock"
    get "locks", to: "/sync/v1/locks#index"

    # hydration
    post "chunks/download", to: "/sync/v1/chunks#download"

    # read-only share links (owner side, authenticated) + anonymous redeem
    resources :share_links, only: %i[create destroy], controller: "/sync/v1/share_links"
    get  "share/:token",          to: "/sync/v1/share#show"
    post "share/:token/download", to: "/sync/v1/share#download"

    # the `local` chunk backend's own presigned-style blob tier (HMAC-authorized, no bearer token)
    put "chunks/blob/:user_id/:hash", to: "/sync/v1/chunks/blob#upload", constraints: { hash: /[0-9a-f]+/ }
    get "chunks/blob/:user_id/:hash", to: "/sync/v1/chunks/blob#download", constraints: { hash: /[0-9a-f]+/ }
  end

  # DEV/TEST-ONLY blob endpoint backing Sync::Storage::MemoryChunkStore's presigned URLs -- see
  # this dummy's app/controllers/dev_blobs_controller.rb for the fuller story (a SECOND,
  # independent finding: MemoryChunkStore's presign_put/presign_get hand back "/dev/blobs/..."
  # URLs as plain strings, so the memory chunk store itself has zero host coupling, but nothing
  # actually SERVES that path without a host providing this route + controller too). Mirrors the
  # host's config/routes.rb line for line.
  get "dev/blobs/*key", to: "dev_blobs#show",   format: false, as: :dev_blob
  put "dev/blobs/*key", to: "dev_blobs#update", format: false

  # NO explicit `mount ActionCable.server => "/cable"` here, unlike the host's own routes.rb --
  # ActionCable::Engine's own "action_cable.routes" initializer (actioncable's engine.rb) already
  # `routes.prepend`s that exact mount for every host that loads the action_cable railtie, at
  # config.action_cable.mount_path (default "/cable"), which this dummy does
  # (config/application.rb). An explicit second mount at the same path is therefore redundant, not
  # merely harmless -- left out rather than kept as belt-and-braces.
end
