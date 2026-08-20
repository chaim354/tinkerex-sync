# Targeted orphaned-chunk reaper job — the cheap, frequent complement to Sync::ChunkReaperJob.
#
# Where Sync::ChunkReaperJob (G4) ENUMERATES the object-storage keyspace weekly (list_objects_v2
# is billed per request), this job does NO bucket list at all: it finds expired, never-
# finalized `pending_commits` and deletes precisely the chunk hashes their manifests
# uploaded (DB read + targeted deletes only). That makes it cheap enough to run HOURLY, so
# the common abandoned-upload leak is reclaimed promptly instead of waiting up to a week.
#
# The two reapers do NOT apply the same guards, and an earlier version of this line said they
# did. G4 unions EVERY pending row with no age filter; this one excludes the expired rows it is
# destroying, which is the only reason it can reclaim anything. Narrow G4 to match and the
# weekly backstop can delete a chunk a slow live commit is about to finalize. See
# Sync::PendingCommitReaper. The weekly ChunkReaper stays as the catch-all backstop for any
# leak with no pending row to expire. Per-user errors are isolated in reap_all!.
#
# STAGE 3b PHASE A CLOSE-OUT moved this from the bare top-level `PendingCommitReaperJob` to
# `Sync::PendingCommitReaperJob` — see app/jobs/sync/retention_job.rb's own comment for why
# this was missed by Tasks 3/4 and the compact-form + explicit `::ApplicationJob` reasoning.
class Sync::PendingCommitReaperJob < ::ApplicationJob
  queue_as :background

  def perform(ttl: Sync::PendingCommitReaper::TTL, dry_run: false)
    reaped = Sync::PendingCommitReaper.reap_all!(ttl:, dry_run:)
    Rails.logger.info("PendingCommitReaperJob #{dry_run ? '[dry-run] would reap' : 'reaped'} " \
                      "#{reaped} orphan chunk(s) across all users")
    reaped
  end
end
