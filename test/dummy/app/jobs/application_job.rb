# A GENUINE FINDING OF THIS TASK: `::ApplicationJob` is a FOURTH host constant the engine
# requires that TinkerexSync::HOST_MODELS (lib/tinkerex_sync.rb: User, Node, Device) does not
# name, and that ArchitectureInvariantsTest::HOST_CONSTANTS (FileLayer, LibraryCapabilities,
# Maker, ApplicationController) does not guard either. All three of the engine's job classes say
# it plainly: `class Sync::ChunkReaperJob < ::ApplicationJob` (and PendingCommitReaperJob,
# RetentionJob) -- and two of those three files' own comments already flag the gap ("missed by
# Tasks 3/4 and the compact-form + explicit ::ApplicationJob reasoning"), which is how this was
# found: by reading the code the boot proof was about to exercise, not by grepping a list that
# does not mention it. Without this file, `bin/rails runner 'Sync::RetentionJob'` in a bare mount
# raises `uninitialized constant ApplicationJob` at class-load time -- before any job runs.
#
# Byte-identical to the host's app/jobs/application_job.rb (itself the untouched Rails scaffold).
class ApplicationJob < ActiveJob::Base
end
