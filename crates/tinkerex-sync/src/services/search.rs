//! Name/path substring search over one user's tree: a single recursive CTE reconstructs each
//! path from the `parent_node_id` chain, tenant-scoped at both the seed and the recursive step,
//! deleted-filtered at every level, depth-capped against a cyclic chain.

use serde::Serialize;

use crate::db::{Db, Query};
use crate::error::ApiResult;

pub const MAX_LIMIT: i64 = 200;
pub const MAX_DEPTH: i64 = 4096;

#[derive(Debug, Serialize)]
pub struct SearchResult {
    pub node_id: String,
    pub name: String,
    pub kind: String,
    pub path: String,
    pub size: Option<i64>,
}

/// Escape LIKE wildcards so the query matches literally (paired with `ESCAPE '\'`).
pub fn escape_like(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if matches!(c, '\\' | '%' | '_') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

pub async fn call(
    db: &Db,
    user_id: i64,
    query: &str,
    include_deleted: bool,
    limit: i64,
    offset: i64,
) -> ApiResult<Vec<SearchResult>> {
    let q = query.trim();
    let limit = limit.clamp(1, MAX_LIMIT);
    let offset = offset.max(0);
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let pattern = format!("%{}%", escape_like(&q.to_lowercase()));
    // A bound boolean instead of a dialect literal: `$5` is `false`, and the clause is dropped
    // entirely when tombstones are wanted.
    let del = if include_deleted {
        ""
    } else {
        " AND n.deleted = $5"
    };
    let sql = format!(
        "WITH RECURSIVE tree(node_id, name, kind, deleted, current_version_id, path, depth) AS ( \
           SELECT n.node_id, n.name, n.kind, n.deleted, n.current_version_id, '/' || n.name, 0 \
             FROM nodes n WHERE n.user_id = $1 AND n.parent_node_id IS NULL{del} \
           UNION ALL \
           SELECT n.node_id, n.name, n.kind, n.deleted, n.current_version_id, tree.path || '/' || n.name, tree.depth + 1 \
             FROM nodes n JOIN tree ON n.parent_node_id = tree.node_id \
            WHERE n.user_id = $1 AND tree.depth < {MAX_DEPTH}{del}) \
         SELECT tree.node_id, tree.name, tree.kind, tree.path, v.size AS size FROM tree \
           LEFT JOIN versions v ON v.version_id = tree.current_version_id AND v.user_id = $1 \
          WHERE LOWER(tree.path) LIKE $2 ESCAPE '\\' \
          ORDER BY tree.path LIMIT $3 OFFSET $4"
    );
    let mut query = Query::new(sql)
        .bind(user_id)
        .bind(pattern)
        .bind(limit)
        .bind(offset);
    if !include_deleted {
        query = query.bind(false);
    }
    let rows = db.fetch_all(&query).await?;
    rows.iter()
        .map(|r| {
            Ok(SearchResult {
                node_id: r.str("node_id")?,
                name: r.str("name")?,
                kind: r.str("kind")?,
                path: r.str("path")?,
                size: r.opt_i64("size")?,
            })
        })
        .collect::<Result<Vec<_>, sqlx::Error>>()
        .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn like_escaping() {
        assert_eq!(escape_like("100%_done\\"), "100\\%\\_done\\\\");
        assert_eq!(escape_like("plain"), "plain");
    }
}
