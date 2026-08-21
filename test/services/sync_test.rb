require "test_helper"

# Unit tests for the bare Sync module's own class methods — Sync.engine_present?, the Stage 3a
# seam standing in for "is the sync engine mounted?" (see
# engines/tinkerex-sync/lib/tinkerex_sync/sync_module.rb for the full argument against spelling it
# as `LIBRARY_BACKEND == "chunk"` inline, or as `FileLayer.current.capabilities.syncable?`); and,
# since Stage 3b Task 9, Sync.capability_available?/.capability_unavailable_message, the
# host-configurable capability-gate seam that replaced the engine's direct
# `::LibraryCapabilities`/`::FileLayer` references (CLAUDE.md §14j).
#
# THIS FILE MOVED WITH THE MODULE IT TESTS -- the module lives in
# engines/tinkerex-sync/lib/tinkerex_sync/sync_module.rb now, not app/services/sync.rb (Stage 3b
# Phase B), but the test itself stays host-side: no engine test scaffolding exists yet (Task 9's
# own plan item), so engine coverage still rides in this app's flat test/ tree, same as every
# other engine unit exercised from here.
#
# PURE — no database, no Rails boot machinery — so, like PostgresPoolerCheck.probe?
# (test/lib/postgres_pooler_check_test.rb), it runs identically on every `bin/ci` leg regardless
# of which LIBRARY_BACKEND that leg is testing. `env:` is injected per assertion rather than
# mutating real ENV (contrast test_helper.rb's `pin_file_layer_backend`, which exists for tests
# that need FileLayer.current itself to resolve to a real adapter) — nothing in the engine_present?
# tests below needs teardown. The capability tests DO: config/initializers/sync_capabilities.rb
# wires Sync.capability_check/.capability_message once, at boot, to this app's real answers, so by
# the time any test here runs the accessors already hold THIS HOST's wiring, not the standalone
# default — proving the default means temporarily swapping in the two named DEFAULT_* constants
# and restoring the host's real wiring afterward, in `ensure`. The identical "you broke it, you put
# it back" contract test_helper.rb#pin_sync_hooks_subscribers states for Sync::Hooks' subscriber
# list — skipping the restore would silently break every OTHER test in this run that exercises a
# capability gate, because this is process-global state, not per-test.
class SyncTest < ActiveSupport::TestCase
  test "engine_present? is true for the chunk backend" do
    assert Sync.engine_present?(env: { "LIBRARY_BACKEND" => "chunk" })
  end

  test "engine_present? defaults to true when LIBRARY_BACKEND is unset" do
    # Mirrors FileLayer.build's own ENV.fetch("LIBRARY_BACKEND", "chunk") default. An
    # unconfigured deployment runs chunk, so an empty env must read as engine-present too —
    # otherwise the pooler guard this predicate feeds would silently stop protecting the most
    # common deployment shape the moment an operator's env lacked the var entirely.
    assert Sync.engine_present?(env: {})
  end

  test "engine_present? is false for the share backend" do
    refute Sync.engine_present?(env: { "LIBRARY_BACKEND" => "share" })
  end

  test "engine_present? is false for the s3 backend" do
    refute Sync.engine_present?(env: { "LIBRARY_BACKEND" => "s3" })
  end

  test "engine_present? is false for an unrecognized value, not true" do
    # An unknown LIBRARY_BACKEND is FileLayer.build's ArgumentError to raise (its own comment:
    # "unknown LIBRARY_BACKEND ...") — not this predicate's to validate, and duplicating that
    # validation here would give an operator two different explanations for one typo
    # (lib/library_backend_check.rb's own "No `else`" comment makes the identical call). But this
    # predicate must still fail toward "no engine" for anything it does not positively recognize
    # as "chunk" — an ALLOWLIST, not a denylist of the two known alternates (CLAUDE.md §14a's
    # "reject, never normalize" rule, one level up: prefer the failure direction that cannot
    # silently do the dangerous thing). Denylisting `%w[share s3]` would leave a typo'd
    # LIBRARY_BACKEND reading as engine-present, which is exactly backwards: a deployment that is
    # about to fail to boot anyway (FileLayer.build's ArgumentError) has no business being told
    # first that it must satisfy a Postgres locking rule it may not even need.
    refute Sync.engine_present?(env: { "LIBRARY_BACKEND" => "share3" })
  end

  # STAGE 3b TASK 9's REQUIRED PROOF: a bare mount, nothing configured, must answer every
  # capability question "available." Not a claim — this is what "unavailable" mutated in would
  # actually break, since test/integration/v1/capability_gating_test.rb only ever exercises THIS
  # HOST's real wiring (share/s3 unavailable, chunk available) and would stay green regardless of
  # what the engine's OWN default happens to be.
  test "capability_available? defaults to true, unconditionally, with nothing configured" do
    original_check = Sync.capability_check
    Sync.capability_check = Sync::DEFAULT_CAPABILITY_CHECK

    assert Sync.capability_available?(:syncable)
    assert Sync.capability_available?(:versioned)
    # ANY capability, not only the two the engine's own controllers gate on today — the
    # standalone default answers the question "does this deployment have X" the same way for
    # every X, because a bare engine has nothing that could ever say no.
    assert Sync.capability_available?(:something_nobody_has_named_yet)
  ensure
    Sync.capability_check = original_check
  end

  test "capability_unavailable_message defaults to a generic, capability-named sentence" do
    original_message = Sync.capability_message
    Sync.capability_message = Sync::DEFAULT_CAPABILITY_MESSAGE

    assert_match(/syncable/, Sync.capability_unavailable_message(:syncable))
  ensure
    Sync.capability_message = original_message
  end
end
