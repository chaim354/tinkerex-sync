# The one environment this dummy app has. Mirrors the host's config/environments/test.rb only
# where the reason still applies with no maker layer, no rate limiting, and no ActiveStorage
# present -- see each setting's own comment for what carried over and what did not.
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr
  config.action_controller.raise_on_missing_callback_actions = true

  # No config.cache_store override, unlike the host: there is no rate limiting here to need a
  # real MemoryStore (that whole concern -- Users::SessionsController's throttles -- is a Devise/
  # web-auth feature, entirely host-side), so Rails' plain test-env default is correct as is.

  # ActiveJob: the plain `:test` adapter, matching the gemspec's own claim that "engine jobs are
  # plain ActiveJob" -- no solid_queue dependency (deliberately absent, see tinkerex-sync.gemspec).
  # Enqueued jobs collect in ActiveJob::Base.queue_adapter.enqueued_jobs for any test that wants
  # to assert against them.
  config.active_job.queue_adapter = :test

  # ActionCable: Rails' built-in :test adapter (no solid_cable dependency, for the same reason as
  # ActiveJob above) -- exactly what ActionCable::TestHelper's assert_broadcast_on expects.
  #
  # `config.action_cable.cable = {...}`, NOT `config.action_cable.adapter = :test` -- tried first
  # and failed loudly: ActionCable::Engine's own "action_cable.set_configs" initializer does
  # `options.each { |k, v| send("#{k}=", v) }` over EVERY key under config.action_cable, so an
  # `adapter` key sent `configuration.adapter = :test` against `ActionCable::Server::Configuration`,
  # which has no such setter (only `cable=`, a Hash `pubsub_adapter` reads `cable.fetch("adapter")`
  # from) -- `NoMethodError: undefined method 'adapter=' for an instance of
  # ActionCable::Server::Configuration`, raised from inside routes reloading (Sync::LibraryChannel's
  # broadcast target triggers `ActionCable.server`), so it surfaced as "No route matches" on every
  # OTHER test in the same run, not as an adapter error -- the real exception only appeared once a
  # test exercised ActionCable directly. In real Rails apps this hash normally comes from
  # config/cable.yml; a plain config-line default is simpler for a dummy this small.
  config.action_cable.cable = { "adapter" => "test" }
end
