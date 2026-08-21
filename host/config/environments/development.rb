Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true

  # A LOCAL CHUNK STORE BY DEFAULT, so `bin/rails server` is enough to try this against a real
  # client. STORAGE_BACKEND=s3 plus the CHUNK_* variables points it at real object storage.
  ENV["STORAGE_BACKEND"] ||= "local"
end
