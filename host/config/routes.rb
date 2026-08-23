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
  # TOUCHES THE DATABASE, because a static 200 is worse than no healthcheck at all. The first real
  # deployment of this app reported healthy on both proxy hostnames while its schema was EMPTY --
  # `Could not find table 'users'` the moment anything read one. A probe that cannot fail tells an
  # orchestrator to send traffic to an app that cannot serve it.
  #
  # Cheap on purpose: one count against the smallest host table, not a query per engine table. It
  # answers "is there a schema and can I reach it", which is the question that was silently wrong.
  get "up", to: proc {
    begin
      User.count
      [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ]
    rescue StandardError => e
      [ 503, { "Content-Type" => "text/plain" }, [ "not ready: #{e.class}" ] ]
    end
  }

  # Local-only chunk blobs, so `bin/rails server` with STORAGE_BACKEND=local is a working sync
  # server with no object storage to stand up. A real deployment sets STORAGE_BACKEND=s3 and these
  # are never reached.
  get "dev/blobs/*key", to: "dev_blobs#show",   format: false, as: :dev_blob
  put "dev/blobs/*key", to: "dev_blobs#update", format: false
end
