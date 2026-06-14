# Periodic version-retention sweep. Scheduled as a Solid Queue recurring task (see
# config/recurring.yml). For every user it applies the configured retention policy
# (RETENTION_POLICY env; defaults to keep_all → self-host prunes nothing) and then sweeps
# refcount-0 chunks, freeing both the DB rows and the object-storage bytes.
#
# It delegates entirely to Sync::Gc.apply_retention! — the tested mechanism — so this job
# stays a thin scheduler. Per-user work is isolated: one user's error is logged and the
# sweep continues for the rest (a bad row shouldn't stall the whole library's GC).
class RetentionJob < ApplicationJob
  queue_as :background

  def perform(grace: 1.hour)
    policy = Sync::RetentionPolicy.default
    User.find_each do |user|
      Sync::Gc.apply_retention!(user, policy:, grace:)
    rescue => e
      Rails.logger.error("RetentionJob failed for user #{user.id}: #{e.class}: #{e.message}")
    end
  end
end
