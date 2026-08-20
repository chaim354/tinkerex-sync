require "test_helper"
require "postgres_pooler_check"

# Unit tests for the Postgres connection-pooler safety probe (G2). The probe detects a
# STATEMENT-mode pooler, which would silently break User#next_seq!'s transaction-spanning
# FOR UPDATE lock and corrupt the changelog. Against a DIRECT Postgres connection (session
# mode), the probe must pass — a leg no CI gate currently runs, since none sets a Postgres
# DATABASE_URL. What DOES run everywhere is `probe?`, the pure eligibility predicate the boot
# initializer gates on; see the comment above those tests for what they do and do not pin.
#
# Stage 3a added a FOURTH thing `probe?` decides, alongside adapter prefix and
# DB_SKIP_POOLER_CHECK: whether this deployment has a changelog at all
# (`engine_present:`, defaulting to Sync.engine_present?). Those tests inject
# `engine_present:` directly rather than LIBRARY_BACKEND — that kwarg, not the ENV var, is
# `probe?`'s actual contract, and test/services/sync_test.rb already pins that
# Sync.engine_present? reads LIBRARY_BACKEND correctly; duplicating that mapping here would only
# be a second copy that could drift from the first. One PRE-EXISTING test below
# ("probe? accepts a Postgres adapter") had to start pinning `engine_present: true` explicitly —
# it used to rely on the default, which is fine under `bin/rails test` (ambient LIBRARY_BACKEND
# unset → chunk → engine present) but would have started failing under the share/s3 `bin/ci` legs
# the moment the default stopped always being true, since its whole point is the ADAPTER check
# and it must stay leg-agnostic (config/ci.rb's "ambient LIBRARY_BACKEND" trap, one level up).
class PostgresPoolerCheckTest < ActiveSupport::TestCase
  def postgres?
    ActiveRecord::Base.connection_pool.db_config.adapter.to_s.start_with?("postgres")
  end

  test "probe passes on a direct (session-mode) Postgres connection" do
    skip "Postgres-only (set DATABASE_URL=postgres…)" unless postgres?
    result = ActiveRecord::Base.connection_pool.with_connection do |conn|
      PostgresPoolerCheck.probe(conn)
    end
    assert_nil result.error, "probe should not error on a direct connection: #{result.error&.message}"
    assert result.same_backend, "two statements in one tx must hit the same backend pid"
    assert result.lock_held, "a session advisory lock must be visible in a later statement"
    assert result.ok, "probe should report OK (session/transaction mode) on a direct connection"
  end

  test "failure_message names the changelog risk and the fix" do
    msg = PostgresPoolerCheck.failure_message(
      PostgresPoolerCheck::Result.new(ok: false, same_backend: false, lock_held: false, error: nil)
    )
    assert_includes msg, "STATEMENT-mode"
    assert_includes msg, "next_seq!"
    assert_includes msg, "TRANSACTION"
    assert_includes msg, "DB_SKIP_POOLER_CHECK"
  end

  # `probe?` is the boot gate's ELIGIBILITY decision, pulled out of the initializer so it can be
  # asserted with no database at all — the same three assertions run identically on every leg.
  # What stood here before was `refute adapter.start_with?("postgres")` behind
  # `skip "only meaningful on SQLite" if postgres?`: the assertion WAS the skip condition, so it
  # was unfalsifiable by construction, and it never called anything the initializer calls.
  #
  # RESIDUAL, stated plainly rather than papered over: these pin what `probe?` ANSWERS, not that
  # the initializer still CALLS it. Delete the call site in
  # config/initializers/postgres_pooler_check.rb and all three stay green. No RUNTIME test can
  # catch that on a SQLite leg, and no `bin/ci` leg sets a Postgres DATABASE_URL — every leg is
  # SQLite. The wiring is therefore UNGUARDED here; do not write a comment claiming otherwise,
  # which is exactly the false confidence the comment this replaced gave.
  # (A STATIC source assertion WOULD close it on every leg — the shape `ci_hygiene_test.rb`,
  # `deploy_hygiene_test.rb` and `architecture_invariants_test.rb` already use. Deliberately not
  # added here: it is a new guard needing its own mutation check, not part of this fix.)
  #
  # Three separate tests, not one with three assertions: minitest aborts a test method at its
  # first failure, so an inverted adapter check would report ONE failure instead of two and the
  # Postgres direction would never be shown to carry weight.
  test "probe? refuses a non-Postgres adapter" do
    refute PostgresPoolerCheck.probe?(adapter: "sqlite3"), "the PG-only probe must never run on SQLite"
  end

  test "probe? accepts a Postgres adapter" do
    # engine_present: true is pinned explicitly (not left to the default) because this test's
    # whole point is the ADAPTER match, and it must stay TRUE regardless of which `bin/ci` leg is
    # running — the default reads ambient LIBRARY_BACKEND, which is "share"/"s3" for two of the
    # three legs and would silently flip this assertion false without this pin.
    assert PostgresPoolerCheck.probe?(adapter: "postgresql", engine_present: true),
           "an over-matching guard would silently disable the probe on real Postgres"
  end

  test "probe? honours the DB_SKIP_POOLER_CHECK escape hatch" do
    refute PostgresPoolerCheck.probe?(adapter: "postgresql", env: { "DB_SKIP_POOLER_CHECK" => "1" }),
           "DB_SKIP_POOLER_CHECK=1 is the bypass failure_message tells operators to use"
  end

  # Stage 3a: the pooler guard must not refuse a boot for a deployment with no changelog. Two
  # separate tests, not one — same reasoning as the trio above: minitest stops at the first
  # failure, so folding both directions into one test would let either direction go unproven
  # without the suite ever saying so.
  test "probe? refuses to run when the engine is absent, even for a Postgres adapter" do
    refute PostgresPoolerCheck.probe?(adapter: "postgresql", env: {}, engine_present: false),
           "a share/s3 deployment has no changelog and must never be refused a boot over " \
           "next_seq!'s lock rule"
  end

  test "probe? still runs when the engine is present" do
    assert PostgresPoolerCheck.probe?(adapter: "postgresql", env: {}, engine_present: true),
           "the engine gate must not swallow the original adapter check for a chunk deployment"
  end
end
