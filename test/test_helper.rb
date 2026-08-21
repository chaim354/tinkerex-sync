ENV["RAILS_ENV"] ||= "test"
require_relative "dummy/config/environment"
require "rails/test_help"

# THE SPLIT CLAUDE.md §14j / this task's brief asked for: the host's test/test_helper.rb embeds
# BOTH pin_sync_hooks_subscribers (Sync::Hooks -- engine) and with_concurrent_file_attachment
# (Maker::FileAttachment -- host) in one shared base every test in that suite requires. This file
# is the engine's own half. Only pin_sync_hooks_subscribers is ported -- with_concurrent_file_attachment
# has no meaning here at all (Maker::FileAttachment does not exist in a bare mount), and nothing
# moved into this suite calls it (verified before this file was written, not assumed).
module ActiveSupport
  class TestCase
    # Deliberately NOT parallelized. The host's test_helper.rb parallelizes across CPU cores with
    # a per-worker chunk dir (CHUNK_STORE_WORKER) because its suite is thousands of tests; this
    # one is small enough that sequential execution is simpler and avoids re-deriving per-worker
    # isolation for Sync::Storage::MemoryChunkStore's on-disk dev-chunks directory (test/dummy/tmp/
    # dev-chunks) that the host needed for a much larger, multi-hour-saved parallel run.

    # Run a block with Sync::Hooks' subscriber list swapped out (Stage 3a Task 4). Byte-identical
    # to the host's copy (test/test_helper.rb) -- Sync::Hooks is entirely engine-owned, so this
    # needed no adaptation at all, only relocation.
    #
    # Sync::Hooks.subscribers is a class-level ivar with nothing registered by default in a bare
    # mount (no config/initializers/sync_hooks.rb here -- there is nothing to subscribe, which is
    # itself the property Sync::Hooks' own design guarantees: "a host that registers nothing still
    # works", CLAUDE.md §14j). Kept anyway, for the tests that fault-inject a raising subscriber or
    # assert on the subscriber list's own shape (moved commit_finalize_transaction_boundary_test.rb
    # is exactly this).
    def pin_sync_hooks_subscribers
      prior = Sync::Hooks.subscribers.dup
      Sync::Hooks.reset!
      yield
    ensure
      Sync::Hooks.reset!
      prior.each { |subscriber| Sync::Hooks.on_commit_finalized(&subscriber) }
    end
  end
end

module ActionDispatch
  class IntegrationTest
    # Trimmed from the host's test_helper.rb: the same shape (build a confirmed user + its first
    # device directly, no HTTP), minus everything Devise-shaped (confirmed_at, omniauth_signup)
    # that this dummy's User model does not carry at all -- see test/dummy/app/models/user.rb's
    # own header for why those columns were never ported. Keys are strings for the same reason the
    # host's version gives: matching the JSON shape the removed POST /v1/auth/register endpoint
    # returned, which several moved tests still destructure as `bootstrap_account(...)["device_token"]`.
    def bootstrap_account(email:, device_name: "device")
      user = User.find_by(email:) || User.create!(email:)
      device = Device.register!(user:, name: device_name)
      {
        "user_id" => user.id, "device_id" => device.id,
        "device_token" => device.plaintext_token, "head_seq" => user.head_seq
      }
    end

    def bootstrap_token(email:, device_name: "device")
      bootstrap_account(email:, device_name:)["device_token"]
    end
  end
end
