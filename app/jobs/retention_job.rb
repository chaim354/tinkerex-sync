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

  # ONE RETENTION PASS AT A TIME, GLOBALLY — this job iterates every user itself, so there is no
  # per-user key to hang a limit on and a global one costs nothing at a nightly cadence.
  #
  # WHY IT MATTERS EVEN THOUGH THE SCHEDULE IS DAILY: Sync::Gc.apply_retention! loads its version
  # lists OUTSIDE any lock, so two passes running together can both select the same version for
  # pruning. Sync::Gc.prune_version! now claims the version row before decrementing, which makes
  # the double-decrement impossible on its own — this limit is the belt to that braces, and it
  # also covers the case the schedule cannot rule out: an operator kicking off a manual pass while
  # the nightly one is still running, or a pass over a large library still going 24 hours later.
  #
  # :block, NOT :discard, and this is the one place the opposite choice from the scan jobs is
  # right. A skipped scan is re-taken 15 minutes later; retention runs once a day, so dropping a
  # tick means a day of un-pruned versions and unswept chunk bytes. Blocking runs it late instead.
  limits_concurrency to: 1, key: "retention", duration: 6.hours, on_conflict: :block

  def perform(grace: 1.hour)
    policy = Sync::RetentionPolicy.default
    User.find_each do |user|
      Sync::Gc.apply_retention!(user, policy:, grace:)
    rescue => e
      Rails.logger.error("RetentionJob failed for user #{user.id}: #{e.class}: #{e.message}")
    end
  end
end
