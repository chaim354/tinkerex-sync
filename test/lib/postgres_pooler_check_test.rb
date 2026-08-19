require "test_helper"
require "postgres_pooler_check"

# Unit tests for the Postgres connection-pooler safety probe (G2). The probe detects a
# STATEMENT-mode pooler, which would silently break User#next_seq!'s transaction-spanning
# FOR UPDATE lock and corrupt the changelog. Against a DIRECT Postgres connection (session
# mode), the probe must pass — a leg no CI gate currently runs, since none sets a Postgres
# DATABASE_URL. What DOES run everywhere is `probe?`, the pure eligibility predicate the boot
# initializer gates on; see the comment above those three tests for what they do and do not pin.
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
    assert PostgresPoolerCheck.probe?(adapter: "postgresql"),
           "an over-matching guard would silently disable the probe on real Postgres"
  end

  test "probe? honours the DB_SKIP_POOLER_CHECK escape hatch" do
    refute PostgresPoolerCheck.probe?(adapter: "postgresql", env: { "DB_SKIP_POOLER_CHECK" => "1" }),
           "DB_SKIP_POOLER_CHECK=1 is the bypass failure_message tells operators to use"
  end
end
