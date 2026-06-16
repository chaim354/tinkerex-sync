# Targeted orphaned-chunk reaper job — the cheap, frequent complement to ChunkReaperJob.
#
# Where ChunkReaperJob (G4) ENUMERATES the object-storage keyspace weekly (list_objects_v2
# is billed per request), this job does NO bucket list at all: it finds expired, never-
# finalized `pending_commits` and deletes precisely the chunk hashes their manifests
# uploaded (DB read + targeted deletes only). That makes it cheap enough to run HOURLY, so
# the common abandoned-upload leak is reclaimed promptly instead of waiting up to a week.
#
# Both reapers apply the same safety guards (dedup-committed + live-pending); see
# Sync::PendingCommitReaper. The weekly ChunkReaper stays as the catch-all backstop for any
# leak with no pending row to expire. Per-user errors are isolated in reap_all!.
class PendingCommitReaperJob < ApplicationJob
  queue_as :background

  def perform(ttl: Sync::PendingCommitReaper::TTL, dry_run: false)
    reaped = Sync::PendingCommitReaper.reap_all!(ttl:, dry_run:)
    Rails.logger.info("PendingCommitReaperJob #{dry_run ? '[dry-run] would reap' : 'reaped'} " \
                      "#{reaped} orphan chunk(s) across all users")
    reaped
  end
end
