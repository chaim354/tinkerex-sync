# THE ENGINE'S OWN ROUTES, IN ONE PLACE, DRAWN BY WHOEVER HOSTS IT.
#
# NOT AT config/routes.rb, DELIBERATELY, AND THE FIRST DRAFT WAS. Rails::Engine reserves that path:
# it has its own `routes` initializer that evaluates the file, so putting the drawer there loaded it
# TWICE and Ruby said so -- `warning: already initialized constant Sync::V1_ROUTES`, caught by
# diffing `bin/rails routes` before and after rather than by reading it. Living under lib/ makes the
# point structurally instead of in a comment: this is not a mounted engine's route file, because
# this engine is not mounted.
#
# WHY THIS IS A DRAWER AND NOT `mount Sync::Engine => "/v1"`, which is what a mountable engine
# usually does. The sync routes are not a contiguous block under a prefix of their own: they are
# INTERLEAVED with the host's inside a single `namespace :v1` -- `devices/login` and
# `resources :devices` (host, per §14j: a Device token is the only credential the whole v1 API
# accepts, maker endpoints included) sit above them, the entire `namespace :maker` sits between
# them, and `chunks/download`, `share_links`, `share/:token` and `chunks/blob` sit below it. A
# mount owns a whole path prefix; it cannot express "these paths, among those."
#
# AND THE URLS CANNOT MOVE. Real desktop clients are deployed against /v1/commit, /v1/changes,
# /v1/tree. Introducing a /v1/sync/ prefix to make a mount possible would break every one of them,
# which is a far worse trade than a method call.
#
# WHAT THIS FIXES. Phase B moved every Sync::V1::* controller into the engine and left the routing
# in the host's config/routes.rb. Task 9's dummy app then needed the same routes and hand-copied 26
# of them -- two descriptions of one thing, free to drift, which is the shape this arc has spent
# five stages removing. Both callers now draw from here, and a test asserts the two route sets
# agree rather than trusting that they do.
#
# The leading `/` on every `to:` is load-bearing: inside `namespace :v1` an unqualified
# "commits#create" resolves against that namespace and looks for V1::CommitsController, which has
# not existed since Phase B. `/sync/v1/commits#create` is Rails' absolute-controller-path escape.
module Sync
  V1_ROUTES = lambda do
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

    # trash / undelete
    get "trash", to: "/sync/v1/trash#index"
    post "trash/:node_id/restore", to: "/sync/v1/trash#restore"

    # best-effort advisory edit locks
    post "nodes/:node_id/lock", to: "/sync/v1/nodes#lock"
    post "nodes/:node_id/unlock", to: "/sync/v1/nodes#unlock"
    get "locks", to: "/sync/v1/locks#index"

    # chunk dedup check + presigned GETs
    post "chunks/download", to: "/sync/v1/chunks#download"

    # public share links: the owner side (authenticated) and the redeem side (anonymous)
    resources :share_links, only: %i[create destroy], controller: "/sync/v1/share_links"
    get "share/:token", to: "/sync/v1/share#show"
    post "share/:token/download", to: "/sync/v1/share#download"

    # the local chunk store's own signed blob endpoints
    put "chunks/blob/:user_id/:hash", to: "/sync/v1/chunks/blob#upload",
        constraints: { hash: /[0-9a-f]+/ }
    get "chunks/blob/:user_id/:hash", to: "/sync/v1/chunks/blob#download",
        constraints: { hash: /[0-9a-f]+/ }
  end

  # Call from inside a `namespace :v1` block: `Sync.draw_v1_routes(self)`.
  def self.draw_v1_routes(mapper) = mapper.instance_exec(&V1_ROUTES)
end
