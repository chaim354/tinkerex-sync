# THE DUMMY'S ROUTES, WHICH ARE NOW THE ENGINE'S OWN.
#
# This file used to open with a long note explaining that the engine shipped no config/routes.rb,
# that routing had stayed entirely in the host when Phase B moved the controllers, and that what
# followed was a hand-copied subset which "can drift, which is the gap itself, not a decoration on
# it." That was an honest description of a real gap -- and the gap is now closed, so the note is
# gone rather than left to mislead.
#
# The engine has its own config/routes.rb. Both this app and the host call Sync.draw_v1_routes,
# and engine_routes_test.rb asserts the two draw the same paths, so neither can quietly fall
# behind the other. See the engine's routes file for why it is a drawer rather than a mount.
Rails.application.routes.draw do
  namespace :v1 do
    # THE SAME DEFINITION THE HOST DRAWS. This block used to be a hand-copied subset of the host's
    # 26 sync routes -- the drift risk that made fixing the routing gap worth doing at all. If the
    # engine adds a route, this app gets it without anyone remembering to copy it, and
    # engine_routes_test.rb asserts the two agree.
    Sync.draw_v1_routes(self)
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
