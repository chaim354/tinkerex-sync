Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)

  # NO DEFAULT FOR THE CHUNK STORE IN PRODUCTION, deliberately. A sync server that silently fell
  # back to a local disk would look healthy while writing every chunk somewhere a second container
  # cannot read -- the failure shape CLAUDE.md §14e records for Solid Cache resolving to a FileStore
  # in a container's tmp. Missing configuration must be missing, not quietly substituted.
  config.force_ssl = ENV["FORCE_SSL"].present?
end
