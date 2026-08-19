# Postgres connection-pooler safety probe (G2 managed-Postgres hardening).
#
# WHY: the changelog sequence allocator `User#next_seq!` takes a `SELECT … FOR UPDATE` row lock
# that MUST span the read+write of `head_seq` within one transaction on ONE backend connection.
# A connection pooler (PgBouncer/RDS Proxy/Supabase) in STATEMENT mode hands each *statement* a
# possibly-different backend connection, which silently breaks transaction-spanning locks (and
# prepared statements). That could let two concurrent commits allocate a DUPLICATE seq — exactly
# the lost-update corruption the row lock exists to prevent. Statement-mode pooling is therefore
# UNSAFE for this app; only SESSION or TRANSACTION mode is correct.
#
# This module performs a best-effort boot probe: open a transaction and check that two statements
# observe the SAME backend pid AND that a session-scoped advisory lock taken in statement 1 is
# still held in statement 2. Under statement-mode pooling these diverge.
module PostgresPoolerCheck
  ADVISORY_KEY = 424242

  Result = Struct.new(:ok, :same_backend, :lock_held, :error, keyword_init: true)

  # Should the boot probe run at all? PURE — no connection, no I/O, so it is assertable on every
  # CI leg (all of which are SQLite). It answers ELIGIBILITY only: is this adapter one the probe
  # applies to, and has the operator opted out. It says nothing about the OUTCOME — that is
  # `probe` + the initializer's warn/raise branch.
  # `env:` is a kwarg default rather than a captured constant or ivar, so ENV is re-read on every
  # call and a hash injected by one test cannot leak into the next.
  def self.probe?(adapter:, env: ENV)
    return false if env["DB_SKIP_POOLER_CHECK"] == "1"

    adapter.to_s.start_with?("postgres")
  end

  # Run the probe on the given AR connection. Returns a Result. Does NOT raise on a clean
  # statement-mode detection (ok=false); only sets `error` if the probe itself errored.
  def self.probe(conn)
    same_backend = false
    lock_held = false
    conn.transaction do
      pid1 = conn.select_value("SELECT pg_backend_pid()")
      conn.execute("SELECT pg_advisory_lock(#{ADVISORY_KEY})") # void return — execute, not select_value
      pid2 = conn.select_value("SELECT pg_backend_pid()")
      held = conn.select_value(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' " \
        "AND ((classid::bigint << 32) | objid::bigint) = #{ADVISORY_KEY} AND pid = pg_backend_pid()"
      ).to_i
      conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_KEY})")
      same_backend = (pid1 == pid2)
      lock_held = (held >= 1)
    end
    Result.new(ok: same_backend && lock_held, same_backend:, lock_held:, error: nil)
  rescue => e
    Result.new(ok: false, same_backend:, lock_held:, error: e)
  end

  def self.failure_message(result)
    <<~MSG.squish
      [postgres-pooler-check] Detected a STATEMENT-mode connection pooler in front of Postgres
      (statements in one transaction did not stay on a single backend connection:
      same_backend=#{result.same_backend} advisory_lock_held=#{result.lock_held}). This app's
      changelog sequence allocator (User#next_seq!) uses a transaction-spanning SELECT … FOR
      UPDATE row lock; statement-mode pooling silently breaks it and can corrupt the changelog
      with duplicate seqs. Use SESSION or TRANSACTION pool mode (PgBouncer pool_mode=transaction,
      RDS Proxy / Supabase transaction mode). See docs/SYNC_SERVER.md "Connection pooler". Set
      DB_SKIP_POOLER_CHECK=1 to bypass if you have verified the pooler mode independently.
    MSG
  end
end
