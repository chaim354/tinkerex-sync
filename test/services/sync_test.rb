require "test_helper"

# Unit tests for the bare Sync module's own class methods — today just Sync.engine_present?, the
# Stage 3a seam standing in for "is the sync engine mounted?" until Stage 3b gives that question
# an actual answer (see app/services/sync.rb for the full argument against spelling it as
# `LIBRARY_BACKEND == "chunk"` inline, or as `FileLayer.current.capabilities.syncable?`).
#
# PURE — no database, no Rails boot machinery — so, like PostgresPoolerCheck.probe?
# (test/lib/postgres_pooler_check_test.rb), it runs identically on every `bin/ci` leg regardless
# of which LIBRARY_BACKEND that leg is testing. `env:` is injected per assertion rather than
# mutating real ENV (contrast test_helper.rb's `pin_file_layer_backend`, which exists for tests
# that need FileLayer.current itself to resolve to a real adapter) — nothing here needs teardown.
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
end
