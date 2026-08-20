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
#
# ENGINE-CONDITIONAL since Stage 3a: this whole module protects `User#next_seq!`'s row lock and
# NOTHING ELSE, and a share/s3 deployment has no changelog and never calls it — see `probe?`'s
# `engine_present:` kwarg below, and Sync.engine_present? for the full argument.
#
# STAGE 3b PHASE A CLOSE-OUT moved this from the bare top-level `PostgresPoolerCheck` to
# `Sync::PostgresPoolerCheck` — one of five bare engine constants a close-out review found
# after Tasks 3/4 (CLAUDE.md §14j). `lib/` IS Zeitwerk-autoloaded here
# (`config.autoload_lib(ignore: %w[assets tasks])`, config/application.rb) — verified live,
# not assumed, because CLAUDE.md's own drafting of this task believed otherwise — so moving
# this file to `lib/sync/` and renaming the module to the compact `Sync::PostgresPoolerCheck`
# is exactly the Task-3/4 pattern: Zeitwerk expects `lib/sync/postgres_pooler_check.rb` to
# define `Sync::PostgresPoolerCheck`, the same path<->constant correspondence it enforces
# under `app/`. `lib` is SEPARATELY on `$LOAD_PATH` too (Rails::Engine's default
# `paths.add "lib", load_path: true`, unaffected by `autoload_lib`), which is what the
# explicit `require "sync/postgres_pooler_check"` below and in every caller relies on —
# updated from the pre-move `require "postgres_pooler_check"` string, same mechanism, new
# relative path.
module Sync::PostgresPoolerCheck
  ADVISORY_KEY = 424242

  Result = Struct.new(:ok, :same_backend, :lock_held, :error, keyword_init: true)

  # Should the boot probe run at all? PURE — no connection, no I/O, so it is assertable on every
  # CI leg (all of which are SQLite). It answers ELIGIBILITY only: is this adapter one the probe
  # applies to, has the operator opted out, and — Stage 3a — does this DEPLOYMENT even have the
  # thing the probe protects. It says nothing about the OUTCOME — that is `probe` + the
  # initializer's warn/raise branch.
  #
  # `env:` is a kwarg default rather than a captured constant or ivar, so ENV is re-read on every
  # call and a hash injected by one test cannot leak into the next. `engine_present:` is the same
  # shape for the same reason, defaulting to Sync.engine_present? — a share or s3 deployment has
  # no changelog and never calls `User#next_seq!`, so it must never be refused a boot behind a
  # statement-mode pooler for a rule that cannot apply to it. See Sync.engine_present?'s own
  # comment for why that predicate is not `LIBRARY_BACKEND == "chunk"` inlined here, or
  # `FileLayer.current.capabilities.syncable?` — this file only consumes the answer, it does not
  # re-derive it.
  def self.probe?(adapter:, env: ENV, engine_present: Sync.engine_present?)
    return false if env["DB_SKIP_POOLER_CHECK"] == "1"
    return false unless engine_present

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
