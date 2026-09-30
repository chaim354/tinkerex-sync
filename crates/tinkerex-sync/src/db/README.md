# The SQL seam

One hand-written SQL layer over two sqlx pools (SQLite and Postgres). Every query is plain text
with `$N` placeholders, written once; the `Value` enum binds each argument to whichever driver is
active. This file records what the Phase 0.3 spike measured (2026-09-30, sqlx 0.9.0, chrono 0.4.45,
Postgres 16.13, bundled SQLite via libsqlite3-sys 0.37), because the cutover's reversibility rests
on it.

## Findings

| Question | SQLite | Postgres |
|---|---|---|
| `$N` placeholders | Accepted; bound by numeric order, and `$1` may repeat in one statement. | Native. |
| Rails datetime text (`2026-08-25 10:11:12.123456`, `…:13`, `…:14.5`) | Decodes to `chrono::NaiveDateTime` as written. | `timestamp(6)` round-trips a `NaiveDateTime` exactly. |
| What sqlx writes for a bound `NaiveDateTime` | `%Y-%m-%d %H:%M:%S%.f` — six digits when needed, none when zero — which is Rails' format except for trailing zeros (`.500` vs Rails' `.500000`). **We bind the Rails text ourselves** (`Timestamp::to_sqlite_text`) so mixed Ruby/Rust rows are byte-compatible. | Bind the `NaiveDateTime`. |
| Booleans | Rails writes 0/1; sqlx reads them as `bool` and writes `bool` as INTEGER 0/1. | Native. |
| `blob` / `bytea` | `Vec<u8>` both ways. | Same. |
| Write serialization | `Pool::begin_with("BEGIN IMMEDIATE")` + `busy_timeout(15s)`: 8 tasks × 50 `next_seq!` allocations came back gapless `1..400`. | `SELECT … FOR UPDATE` inside `pool.begin()`: same result. |
| The recursive-CTE search | Runs verbatim with binds. A **bound boolean** replaces Rails' `connection.quote(false)` dialect literal, so the SQL text needs no per-dialect branch. | Same text, same binds. |
| 5,000-bind `IN (...)` | Fine (SQLite's default limit is 32,766). | Fine (limit 65,535; the commit path slices at 5,000, as Rails did). |
| Dynamic SQL | sqlx 0.9 refuses a non-literal string unless wrapped in `AssertSqlSafe`; every query here is built from trusted text plus placeholders, never from client data. |

## Conventions the layer enforces

- Connection pragmas on SQLite: `journal_mode=WAL`, `synchronous=NORMAL`, `foreign_keys=ON`,
  `busy_timeout=15000` — read off the Rails-created development database and matched.
- A NULL is always bound with its column's type (`Value::Str(None)`, not an untyped null): Postgres
  infers parameter types from the client's declaration, and an INT8 NULL will not insert into a
  `character varying` column.
- Integers are bound as `i64` everywhere; Postgres applies its assignment cast into `integer`
  columns and compares `int4 = int8` without complaint. Reads try `i64` then fall back to `i32`.
- Timestamps are `Timestamp` (microsecond precision, UTC-naive) — see `src/time.rs` for the three
  textual forms and what pins each.
