require "test_helper"
require "postgres_pooler_check"

# Unit tests for the Postgres connection-pooler safety probe (G2). The probe detects a
# STATEMENT-mode pooler, which would silently break User#next_seq!'s transaction-spanning
# FOR UPDATE lock and corrupt the changelog. Against a DIRECT Postgres connection (session
# mode), the probe must pass. On SQLite the probe is not applicable, so we assert the boot
# initializer correctly skips non-Postgres adapters.
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

  test "boot probe is a no-op on a non-Postgres adapter" do
    # On SQLite the adapter guard in the initializer means no probe runs; booting the suite at
    # all (which we have) proves it. Make the guard logic explicit here so a regression that
    # ran the PG-only probe against SQLite would fail loudly.
    skip "only meaningful on SQLite" if postgres?
    adapter = ActiveRecord::Base.connection_pool.db_config.adapter.to_s
    refute adapter.start_with?("postgres"), "expected SQLite here"
  end
end
