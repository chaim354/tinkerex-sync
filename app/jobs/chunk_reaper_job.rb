# Periodic storage-orphan reaper (G4). Scheduled as a Solid Queue recurring task (see
# config/recurring.yml) on a CONSERVATIVE cadence — it lists the object-storage keyspace
# (billed per request on S3/R2: ~1 list req / 1000 objects), so it runs infrequently and
# off-peak, distinct from the nightly RetentionJob.
#
# It reaps chunk bytes that were uploaded for a commit that never finalized — storage
# objects with NO DB row, which RetentionJob's refcount sweep can never see. The grace
# window protects in-flight uploads (see Sync::ChunkReaper). Delegates to the tested
# Sync::ChunkReaper.reap_all!; per-user errors are isolated there.
class ChunkReaperJob < ApplicationJob
  queue_as :background

  def perform(grace: Sync::ChunkReaper::PENDING_COMMIT_TTL, dry_run: false)
    reaped = Sync::ChunkReaper.reap_all!(grace:, dry_run:)
    Rails.logger.info("ChunkReaperJob #{dry_run ? '[dry-run] would reap' : 'reaped'} " \
                      "#{reaped} orphan chunk(s) across all users")
    reaped
  end
end
