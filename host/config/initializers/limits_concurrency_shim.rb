# A THIRD, SHARPER-EDGED FINDING THAN THE HOST_MODELS/HOST_CONSTANTS GAPS: Sync::RetentionJob's
# class body calls `limits_concurrency to: 1, key: "retention", duration: 6.hours,
# on_conflict: :block` (engines/tinkerex-sync/app/jobs/sync/retention_job.rb). That method does
# NOT exist on core ActiveJob::Base -- it is defined by SOLID QUEUE's
# `ActiveJob::ConcurrencyControls` (gems/solid_queue-*/lib/active_job/concurrency_controls.rb),
# mixed into ActiveJob::Base only by SolidQueue::Engine's own initializer. Confirmed empirically,
# not assumed: `Sync::RetentionJob` class-loads with a bare `NoMethodError: undefined method
# 'limits_concurrency' for class Sync::RetentionJob` the moment eager loading (or this test suite)
# reaches it, under plain active_job/railtie with no solid_queue present.
#
# THIS CONTRADICTS THE GEMSPEC'S OWN CLAIM. tinkerex-sync.gemspec: "Notably absent... the solid_*
# trio (the host chooses its queue adapter; engine jobs are plain ActiveJob)." Two of the three
# job classes ARE plain ActiveJob (Sync::ChunkReaperJob, Sync::PendingCommitReaperJob load and run
# fine here with no shim). Sync::RetentionJob is not: a host that chooses a DIFFERENT queue
# adapter (Sidekiq, GoodJob, plain :async) cannot even DEFINE this class today, let alone run it,
# unless it also happens to have solid_queue's gem loaded for this one API. That is true on every
# real deployment of this app (solid_queue is always present), which is exactly why nobody had
# reason to notice until a bare mount tried to load the engine without it.
#
# REQUIRING THE REAL solid_queue GEM WAS TRIED FIRST AND REJECTED, EMPIRICALLY: `require
# "solid_queue"` alone (i.e. without the full `rails/all` stack this dummy deliberately does not
# load -- see config/application.rb's own comment on selective railties) raised `NameError:
# uninitialized constant ActiveModel` three files deep in solid_queue's own require graph
# (solid_queue/processes/callbacks.rb wants ActiveModel::Callbacks) -- it assumes a full-framework
# boot, not a standalone require, and pulling in active_model/action_view etc. just to satisfy one
# job's class-body call would be adding framework surface this dummy deliberately does not carry,
# for a dependency the engine's own gemspec explicitly says it does not have.
#
# SO THIS IS A SHIM, LABELLED AS ONE, NOT A REIMPLEMENTATION OF SOLID QUEUE'S SEMANTICS -- it
# exists to let `Sync::RetentionJob` class-load and its `perform` body be exercised via
# `perform_now` (moved test/jobs/retention_job_test.rb does exactly this), which never touches
# concurrency control at all: `perform_now` runs a job's body in-process immediately, bypassing
# enqueue/dequeue and therefore the queue adapter's own concurrency-limiting logic entirely,
# real or shimmed. Real concurrency ENFORCEMENT (two overlapping retention passes actually being
# serialized against each other by the queue backend) is NOT exercised by anything in this suite
# and cannot be, without the real solid_queue gem and its DB-backed semaphore. Do not read a green
# suite here as proof that limits_concurrency's runtime behaviour works -- it only proves the
# class LOADS and its own logic (delegating to Sync::Gc.apply_retention! per user) is correct.
class ActiveJob::Base
  def self.limits_concurrency(**)
  end
end
