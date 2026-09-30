//! The SQL seam: one query text, two drivers. See README.md beside this file for the measurements
//! behind every choice here.

use std::time::Duration;

use sqlx::postgres::{PgPool, PgPoolOptions, PgRow};
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqlitePoolOptions, SqliteRow,
    SqliteSynchronous,
};
use sqlx::{Postgres, Row as _, Sqlite, Transaction};

use crate::config::DatabaseConfig;
use crate::time::Timestamp;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dialect {
    Sqlite,
    Postgres,
}

impl Dialect {
    /// The row-lock clause `User#next_seq!` relies on: `FOR UPDATE` on Postgres, nothing on SQLite,
    /// whose `BEGIN IMMEDIATE` already holds the one writer lock for the whole transaction.
    pub fn for_update(self) -> &'static str {
        match self {
            Dialect::Sqlite => "",
            Dialect::Postgres => " FOR UPDATE",
        }
    }
}

/// A bound argument. Every variant is an `Option` so a NULL always carries its column's type.
#[derive(Debug, Clone)]
pub enum Value {
    Bool(Option<bool>),
    I64(Option<i64>),
    Str(Option<String>),
    Bytes(Option<Vec<u8>>),
    Time(Option<Timestamp>),
}

impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Bool(Some(v))
    }
}
impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::I64(Some(v))
    }
}
impl From<i32> for Value {
    fn from(v: i32) -> Self {
        Value::I64(Some(v as i64))
    }
}
impl From<Option<i64>> for Value {
    fn from(v: Option<i64>) -> Self {
        Value::I64(v)
    }
}
impl From<&str> for Value {
    fn from(v: &str) -> Self {
        Value::Str(Some(v.to_string()))
    }
}
impl From<String> for Value {
    fn from(v: String) -> Self {
        Value::Str(Some(v))
    }
}
impl From<Option<String>> for Value {
    fn from(v: Option<String>) -> Self {
        Value::Str(v)
    }
}
impl From<Option<&str>> for Value {
    fn from(v: Option<&str>) -> Self {
        Value::Str(v.map(str::to_string))
    }
}
impl From<Vec<u8>> for Value {
    fn from(v: Vec<u8>) -> Self {
        Value::Bytes(Some(v))
    }
}
impl From<Option<Vec<u8>>> for Value {
    fn from(v: Option<Vec<u8>>) -> Self {
        Value::Bytes(v)
    }
}
impl From<Timestamp> for Value {
    fn from(v: Timestamp) -> Self {
        Value::Time(Some(v))
    }
}
impl From<Option<Timestamp>> for Value {
    fn from(v: Option<Timestamp>) -> Self {
        Value::Time(v)
    }
}

/// SQL text plus its bound arguments, driver-agnostic until executed.
#[derive(Debug, Clone)]
pub struct Query {
    sql: String,
    args: Vec<Value>,
}

impl Query {
    pub fn new(sql: impl Into<String>) -> Self {
        Self {
            sql: sql.into(),
            args: Vec::new(),
        }
    }

    pub fn bind(mut self, v: impl Into<Value>) -> Self {
        self.args.push(v.into());
        self
    }

    pub fn sql(&self) -> &str {
        &self.sql
    }
}

/// `$from, $from+1, ...` for an `IN (...)` list. Built from a count, never from client text.
pub fn placeholders(from: usize, count: usize) -> String {
    (from..from + count)
        .map(|i| format!("${i}"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn sqlite_query(q: &Query) -> sqlx::query::Query<'static, Sqlite, sqlx::sqlite::SqliteArguments> {
    let mut sq = sqlx::query(sqlx::AssertSqlSafe(q.sql.clone()));
    for v in &q.args {
        sq = match v {
            Value::Bool(b) => sq.bind(*b),
            Value::I64(i) => sq.bind(*i),
            Value::Str(s) => sq.bind(s.clone()),
            Value::Bytes(b) => sq.bind(b.clone()),
            Value::Time(t) => sq.bind(t.map(|t| t.to_sqlite_text())),
        };
    }
    sq
}

fn pg_query(q: &Query) -> sqlx::query::Query<'static, Postgres, sqlx::postgres::PgArguments> {
    let mut pq = sqlx::query(sqlx::AssertSqlSafe(q.sql.clone()));
    for v in &q.args {
        pq = match v {
            Value::Bool(b) => pq.bind(*b),
            Value::I64(i) => pq.bind(*i),
            Value::Str(s) => pq.bind(s.clone()),
            Value::Bytes(b) => pq.bind(b.clone()),
            Value::Time(t) => pq.bind(t.map(|t| t.naive())),
        };
    }
    pq
}

/// One result row, read by column name.
pub enum Row {
    Sqlite(SqliteRow),
    Pg(PgRow),
}

impl Row {
    pub fn i64(&self, col: &str) -> sqlx::Result<i64> {
        match self {
            Row::Sqlite(r) => r.try_get::<i64, _>(col),
            Row::Pg(r) => r
                .try_get::<i64, _>(col)
                .or_else(|_| r.try_get::<i32, _>(col).map(i64::from)),
        }
    }

    pub fn opt_i64(&self, col: &str) -> sqlx::Result<Option<i64>> {
        match self {
            Row::Sqlite(r) => r.try_get::<Option<i64>, _>(col),
            Row::Pg(r) => r
                .try_get::<Option<i64>, _>(col)
                .or_else(|_| r.try_get::<Option<i32>, _>(col).map(|o| o.map(i64::from))),
        }
    }

    pub fn str(&self, col: &str) -> sqlx::Result<String> {
        match self {
            Row::Sqlite(r) => r.try_get::<String, _>(col),
            Row::Pg(r) => r.try_get::<String, _>(col),
        }
    }

    pub fn opt_str(&self, col: &str) -> sqlx::Result<Option<String>> {
        match self {
            Row::Sqlite(r) => r.try_get::<Option<String>, _>(col),
            Row::Pg(r) => r.try_get::<Option<String>, _>(col),
        }
    }

    pub fn bool(&self, col: &str) -> sqlx::Result<bool> {
        match self {
            Row::Sqlite(r) => r.try_get::<bool, _>(col),
            Row::Pg(r) => r.try_get::<bool, _>(col),
        }
    }

    pub fn opt_bytes(&self, col: &str) -> sqlx::Result<Option<Vec<u8>>> {
        match self {
            Row::Sqlite(r) => r.try_get::<Option<Vec<u8>>, _>(col),
            Row::Pg(r) => r.try_get::<Option<Vec<u8>>, _>(col),
        }
    }

    pub fn time(&self, col: &str) -> sqlx::Result<Timestamp> {
        self.opt_time(col)?
            .ok_or_else(|| sqlx::Error::ColumnDecode {
                index: col.to_string(),
                source: "unexpected NULL timestamp".into(),
            })
    }

    pub fn opt_time(&self, col: &str) -> sqlx::Result<Option<Timestamp>> {
        match self {
            Row::Sqlite(r) => {
                let text: Option<String> = r.try_get(col)?;
                match text {
                    None => Ok(None),
                    Some(s) => Timestamp::parse_sqlite_text(&s).map(Some).ok_or_else(|| {
                        sqlx::Error::ColumnDecode {
                            index: col.to_string(),
                            source: format!("unparseable datetime text {s:?}").into(),
                        }
                    }),
                }
            }
            Row::Pg(r) => {
                let t: Option<chrono::NaiveDateTime> = r.try_get(col)?;
                Ok(t.map(Timestamp::from_naive))
            }
        }
    }
}

#[derive(Clone)]
pub enum Db {
    Sqlite(SqlitePool),
    Pg(PgPool),
}

impl Db {
    pub async fn connect(cfg: &DatabaseConfig) -> anyhow::Result<Self> {
        match cfg {
            DatabaseConfig::Sqlite { path } => {
                if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
                    std::fs::create_dir_all(parent)?;
                }
                let opts = SqliteConnectOptions::new()
                    .filename(path)
                    .create_if_missing(true)
                    .journal_mode(SqliteJournalMode::Wal)
                    .synchronous(SqliteSynchronous::Normal)
                    .foreign_keys(true)
                    .busy_timeout(Duration::from_millis(15_000));
                let pool = SqlitePoolOptions::new()
                    .max_connections(8)
                    .connect_with(opts)
                    .await?;
                Ok(Db::Sqlite(pool))
            }
            DatabaseConfig::Postgres { url } => {
                let pool = PgPoolOptions::new()
                    .max_connections(16)
                    .connect(url)
                    .await?;
                Ok(Db::Pg(pool))
            }
        }
    }

    pub fn dialect(&self) -> Dialect {
        match self {
            Db::Sqlite(_) => Dialect::Sqlite,
            Db::Pg(_) => Dialect::Postgres,
        }
    }

    /// A WRITE transaction. On SQLite `BEGIN IMMEDIATE` takes the writer lock up front — the shape
    /// Active Record's sqlite3 adapter uses — so two writers never deadlock on a lock upgrade.
    pub async fn begin(&self) -> sqlx::Result<Tx> {
        match self {
            Db::Sqlite(p) => Ok(Tx::Sqlite(p.begin_with("BEGIN IMMEDIATE").await?)),
            Db::Pg(p) => Ok(Tx::Pg(p.begin().await?)),
        }
    }

    pub async fn execute(&self, q: &Query) -> sqlx::Result<u64> {
        match self {
            Db::Sqlite(p) => sqlite_query(q).execute(p).await.map(|r| r.rows_affected()),
            Db::Pg(p) => pg_query(q).execute(p).await.map(|r| r.rows_affected()),
        }
    }

    pub async fn fetch_all(&self, q: &Query) -> sqlx::Result<Vec<Row>> {
        match self {
            Db::Sqlite(p) => Ok(sqlite_query(q)
                .fetch_all(p)
                .await?
                .into_iter()
                .map(Row::Sqlite)
                .collect()),
            Db::Pg(p) => Ok(pg_query(q)
                .fetch_all(p)
                .await?
                .into_iter()
                .map(Row::Pg)
                .collect()),
        }
    }

    pub async fn fetch_optional(&self, q: &Query) -> sqlx::Result<Option<Row>> {
        match self {
            Db::Sqlite(p) => Ok(sqlite_query(q).fetch_optional(p).await?.map(Row::Sqlite)),
            Db::Pg(p) => Ok(pg_query(q).fetch_optional(p).await?.map(Row::Pg)),
        }
    }

    pub async fn fetch_one(&self, q: &Query) -> sqlx::Result<Row> {
        match self {
            Db::Sqlite(p) => Ok(Row::Sqlite(sqlite_query(q).fetch_one(p).await?)),
            Db::Pg(p) => Ok(Row::Pg(pg_query(q).fetch_one(p).await?)),
        }
    }

    pub async fn close(&self) {
        match self {
            Db::Sqlite(p) => p.close().await,
            Db::Pg(p) => p.close().await,
        }
    }
}

pub enum Tx {
    Sqlite(Transaction<'static, Sqlite>),
    Pg(Transaction<'static, Postgres>),
}

impl Tx {
    pub fn dialect(&self) -> Dialect {
        match self {
            Tx::Sqlite(_) => Dialect::Sqlite,
            Tx::Pg(_) => Dialect::Postgres,
        }
    }

    pub async fn execute(&mut self, q: &Query) -> sqlx::Result<u64> {
        match self {
            Tx::Sqlite(t) => sqlite_query(q)
                .execute(&mut **t)
                .await
                .map(|r| r.rows_affected()),
            Tx::Pg(t) => pg_query(q)
                .execute(&mut **t)
                .await
                .map(|r| r.rows_affected()),
        }
    }

    pub async fn fetch_all(&mut self, q: &Query) -> sqlx::Result<Vec<Row>> {
        match self {
            Tx::Sqlite(t) => Ok(sqlite_query(q)
                .fetch_all(&mut **t)
                .await?
                .into_iter()
                .map(Row::Sqlite)
                .collect()),
            Tx::Pg(t) => Ok(pg_query(q)
                .fetch_all(&mut **t)
                .await?
                .into_iter()
                .map(Row::Pg)
                .collect()),
        }
    }

    pub async fn fetch_optional(&mut self, q: &Query) -> sqlx::Result<Option<Row>> {
        match self {
            Tx::Sqlite(t) => Ok(sqlite_query(q)
                .fetch_optional(&mut **t)
                .await?
                .map(Row::Sqlite)),
            Tx::Pg(t) => Ok(pg_query(q).fetch_optional(&mut **t).await?.map(Row::Pg)),
        }
    }

    pub async fn fetch_one(&mut self, q: &Query) -> sqlx::Result<Row> {
        match self {
            Tx::Sqlite(t) => Ok(Row::Sqlite(sqlite_query(q).fetch_one(&mut **t).await?)),
            Tx::Pg(t) => Ok(Row::Pg(pg_query(q).fetch_one(&mut **t).await?)),
        }
    }

    pub async fn commit(self) -> sqlx::Result<()> {
        match self {
            Tx::Sqlite(t) => t.commit().await,
            Tx::Pg(t) => t.commit().await,
        }
    }

    pub async fn rollback(self) -> sqlx::Result<()> {
        match self {
            Tx::Sqlite(t) => t.rollback().await,
            Tx::Pg(t) => t.rollback().await,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholder_lists() {
        assert_eq!(placeholders(1, 3), "$1, $2, $3");
        assert_eq!(placeholders(4, 1), "$4");
        assert_eq!(placeholders(1, 0), "");
    }
}

/// What a service needs from wherever it runs — the pool for reads, a transaction for writes —
/// so each query helper is written once. `Db` is a cheap-to-clone handle, so a caller that only
/// holds a shared reference clones it to satisfy `&mut self`.
#[allow(async_fn_in_trait)]
pub trait Exec {
    fn dialect(&self) -> Dialect;
    async fn execute(&mut self, q: &Query) -> sqlx::Result<u64>;
    async fn fetch_all(&mut self, q: &Query) -> sqlx::Result<Vec<Row>>;
    async fn fetch_optional(&mut self, q: &Query) -> sqlx::Result<Option<Row>>;
    async fn fetch_one(&mut self, q: &Query) -> sqlx::Result<Row>;
}

impl Exec for Db {
    fn dialect(&self) -> Dialect {
        Db::dialect(self)
    }
    async fn execute(&mut self, q: &Query) -> sqlx::Result<u64> {
        Db::execute(self, q).await
    }
    async fn fetch_all(&mut self, q: &Query) -> sqlx::Result<Vec<Row>> {
        Db::fetch_all(self, q).await
    }
    async fn fetch_optional(&mut self, q: &Query) -> sqlx::Result<Option<Row>> {
        Db::fetch_optional(self, q).await
    }
    async fn fetch_one(&mut self, q: &Query) -> sqlx::Result<Row> {
        Db::fetch_one(self, q).await
    }
}

impl Exec for Tx {
    fn dialect(&self) -> Dialect {
        Tx::dialect(self)
    }
    async fn execute(&mut self, q: &Query) -> sqlx::Result<u64> {
        Tx::execute(self, q).await
    }
    async fn fetch_all(&mut self, q: &Query) -> sqlx::Result<Vec<Row>> {
        Tx::fetch_all(self, q).await
    }
    async fn fetch_optional(&mut self, q: &Query) -> sqlx::Result<Option<Row>> {
        Tx::fetch_optional(self, q).await
    }
    async fn fetch_one(&mut self, q: &Query) -> sqlx::Result<Row> {
        Tx::fetch_one(self, q).await
    }
}
