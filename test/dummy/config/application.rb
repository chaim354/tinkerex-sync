require_relative "boot"

# SELECTIVE RAILTIES, NOT `require "rails/all"` -- the inverse of boot.rb's choice, and
# deliberately so: BUNDLE_GEMFILE reuses the monorepo's dependency resolution because a second
# Gemfile would buy nothing, but which RAILTIES this application boots is exactly the question
# this whole task exists to answer for the engine. Loaded: active_record (every engine model),
# active_job (the three Sync::*Job classes -- ::ApplicationJob), action_controller +
# action_cable (Sync::V1::* controllers are ActionController::API; Sync::LibraryChannel is
# ::ApplicationCable::Channel). NOT loaded, and verified nothing under engines/tinkerex-sync/app
# or lib needs them: action_view (every controller renders JSON, never a template),
# action_mailer (no engine model sends mail), active_storage (CLAUDE.md §14j: "ActiveStorage and
# ActionText are clean -- no engine table has an attachment"), action_text, action_mailbox.
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_cable/engine"

# aws-sdk-s3 is the gemspec's other declared dependency (Sync::Storage::S3ChunkStore) -- required
# explicitly because Bundler.require is not in play here (no rails/all, no Bundler.require call:
# this app requires exactly the railties above plus this one gem, by hand, matching boot.rb's
# "minimal framework surface" choice). Not exercised by any test moved into this suite today
# (S3ChunkStore has no unit test -- CLAUDE.md §14j notes it rides inside adapter-contract tests
# that construct a stub client directly), but the engine's own app/services/sync/storage/
# s3_chunk_store.rb references the constant at load time (`Aws::S3::Client`), so eager-loading
# this application without it present would fail exactly where a real host's boot would.
require "aws-sdk-s3"

# THE ENGINE UNDER TEST. Mounting it is this dummy app's whole purpose -- required here, at
# top level, rather than left to the Gemfile's `require: "tinkerex_sync"`, because that only
# fires under `Bundler.require`, which this file deliberately never calls (see the railtie
# comment above: `bundler/setup` in boot.rb sets up load paths only, nothing more).
# `isolate_namespace Sync` (engines/tinkerex-sync/lib/tinkerex_sync/engine.rb) runs as this
# executes, registering Sync::Engine as a Rails::Engine subclass -- which is what lets
# Rails::Application#initialize! find and mount it below, the same mechanism that makes any
# gem-based engine "just work" once required before the host's own Application#initialize!.
require "tinkerex_sync"

module Dummy
  class Application < Rails::Application
    config.load_defaults 8.1

    # No app/models, app/controllers etc. of our OWN beyond the host stand-ins (User, Node,
    # Device, ApplicationRecord, ApplicationJob, ApplicationCable::{Channel,Connection},
    # DevBlobsController) -- config.root defaults correctly to this directory's parent.

    # Test-only application; nothing here is ever deployed, so eager_load/cache_classes etc. are
    # left at config/environments/test.rb's own settings (the one environment this app has).
  end
end
