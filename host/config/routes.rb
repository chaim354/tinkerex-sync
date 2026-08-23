Rails.application.routes.draw do
  namespace :v1 do
    # The engine's own two dozen endpoints. Drawn, not mounted, for the reason
    # lib/tinkerex_sync/v1_routes.rb gives: the paths interleave with a host's inside one namespace,
    # and a mount owns a whole prefix. Here nothing interleaves -- but using the same drawer keeps
    # this host and chaim354/tinkerex on one definition rather than two that can drift.
    Sync.draw_v1_routes(self)

    # The host's own half. Device identity is a host obligation (the engine draws no devices route
    # at all), which is exactly why TinkerexSync::HOST_MODELS names Device.
    resources :devices, only: :create
    get "devices/whoami", to: "devices#whoami"
  end

  # A HEALTH ENDPOINT, because a service meant to be deployed needs one and this had none -- kamal,
  # Docker and every load balancer probe a path, and 404 reads as "the app is broken" rather than
  # "there is nothing here". Found by curling /up on the running host, which no test does.
  get "up", to: proc { [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ] }

  # Local-only chunk blobs, so `bin/rails server` with STORAGE_BACKEND=local is a working sync
  # server with no object storage to stand up. A real deployment sets STORAGE_BACKEND=s3 and these
  # are never reached.
  get "dev/blobs/*key", to: "dev_blobs#show",   format: false, as: :dev_blob
  put "dev/blobs/*key", to: "dev_blobs#update", format: false
end
