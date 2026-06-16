module Sync
  # G9 — server-side file/folder search by name or full path, scoped to one user.
  #
  # Used by the web UI and by a fresh device that has no local SQLite mirror yet (the
  # desktop app does this instantly + offline via `fs-provider`'s local `search`). Matches a
  # case-insensitive substring of the basename *or* the full slash-rooted path, so querying a
  # parent-folder name finds its descendants too. Tombstoned nodes are excluded by default.
  #
  # Path reconstruction is a single **recursive CTE** over the `parent_node_id` chain — one
  # query, no N+1 — and is adapter-agnostic (both SQLite and Postgres support `WITH
  # RECURSIVE`, `||` string concat, and `LIKE ... ESCAPE`). File size comes from a LEFT JOIN
  # to the current version. Results are path-ordered and paginated by `limit`/`offset`.
  #
  # Substring `LIKE` is the must-have; full-text/ranking (SQLite FTS5 / PG `pg_trgm`) is a
  # deliberate follow-up (see `docs/plan-file-layer-parity.md` §10 / G9). Content search is a
  # separate maker-app indexing concern, out of scope here.
  class Search
    MAX_LIMIT = 200

    def self.call(user:, query:, include_deleted: false, limit: MAX_LIMIT, offset: 0)
      q = query.to_s.strip
      limit = limit.to_i.clamp(1, MAX_LIMIT)
      offset = [ offset.to_i, 0 ].max
      # A blank query would match every node; refuse it rather than dump the whole tree.
      return { results: [] } if q.empty?

      pattern = "%#{escape_like(q.downcase)}%"
      rows = connection.exec_query(build_sql(user.id, pattern, include_deleted:, limit:, offset:), "Sync::Search")
      { results: rows.map { |r| serialize(r) } }
    end

    # The recursive CTE: seed from the user's top-level nodes (parent_node_id IS NULL) with
    # their leading-slash path, then walk down the parent_node_id chain appending "/name".
    # Every node is scoped to the caller's user_id at *both* the seed and the recursive step —
    # tenant isolation is enforced in the query itself, never crossing users. The deleted
    # filter is applied at every level so a tombstoned ancestor can't carry descendants into
    # the results either.
    #
    # `user_id`, `limit`, `offset` are coerced to integers (safe to interpolate); only the
    # user-supplied `pattern` is bound + escaped. The deleted-false literal is adapter-quoted.
    def self.build_sql(user_id, pattern, include_deleted:, limit:, offset:)
      uid = user_id.to_i
      lim = limit.to_i
      off = offset.to_i
      del = include_deleted ? "" : "AND n.deleted = #{quoted_false}"
      bound_pattern = connection.quote(pattern)
      <<~SQL.squish
        WITH RECURSIVE tree(node_id, name, kind, deleted, current_version_id, path) AS (
          SELECT n.node_id, n.name, n.kind, n.deleted, n.current_version_id,
                 '/' || n.name
            FROM nodes n
           WHERE n.user_id = #{uid} AND n.parent_node_id IS NULL #{del}
          UNION ALL
          SELECT n.node_id, n.name, n.kind, n.deleted, n.current_version_id,
                 tree.path || '/' || n.name
            FROM nodes n
            JOIN tree ON n.parent_node_id = tree.node_id
           WHERE n.user_id = #{uid} #{del}
        )
        SELECT tree.node_id, tree.name, tree.kind, tree.path, v.size AS size
          FROM tree
          LEFT JOIN versions v ON v.version_id = tree.current_version_id AND v.user_id = #{uid}
         WHERE LOWER(tree.path) LIKE #{bound_pattern} ESCAPE '\\'
         ORDER BY tree.path
         LIMIT #{lim} OFFSET #{off}
      SQL
    end

    def self.serialize(row)
      {
        node_id: row["node_id"],
        name: row["name"],
        kind: row["kind"],
        path: row["path"],
        size: row["size"]&.to_i
      }
    end

    # Escape LIKE wildcards so the query matches literally (paired with `ESCAPE '\'`).
    def self.escape_like(s)
      s.gsub(/[\\%_]/) { |c| "\\#{c}" }
    end

    def self.connection = Node.connection

    # `false` literal that's valid on both adapters (SQLite stores booleans as 0/1).
    def self.quoted_false = connection.quote(false)
  end
end
