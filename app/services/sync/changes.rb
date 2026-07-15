module Sync
  # The pull delta: ordered changelog entries where seq > cursor, each carrying the
  # node's current state and (for content commits) the version's manifest so the
  # client can update its local tree and dehydrate changed placeholders.
  #
  # Batch-loaded (G11): a delta of N entries issues a BOUNDED number of queries
  # (entries page + nodes-in + versions-in + manifest-chunks-in), NOT O(N) per-entry
  # `find_by`s. A far-behind device doing a 2000-entry catch-up must not fire ~6000
  # round-trips. The bulk snapshot path is `Sync::Tree`. Joins are by the string
  # `node_id`/`version_id`/`manifest_id` keys via `where(... IN (...))` — portable
  # across SQLite + Postgres, no PG-only SQL.
  class Changes
    def self.call(user:, since:, limit: 500)
      entries = user.changelog_entries.since(since).limit(limit).to_a

      node_ids = entries.map(&:node_id).uniq
      nodes = node_ids.empty? ? {} :
        user.nodes.where(node_id: node_ids).index_by(&:node_id)

      # Versions are only referenced by `put` entries that name a version.
      version_ids = entries.select { |e| e.op == "put" && e.version_id.present? }
                           .map(&:version_id).uniq
      versions = version_ids.empty? ? {} :
        user.versions.where(version_id: version_ids).index_by(&:version_id)

      manifest_ids = versions.values.map(&:manifest_id).uniq
      manifests = Sync.load_manifests(user, manifest_ids)

      {
        changes: entries.map { |e| serialize(e, nodes, versions, manifests) },
        head_seq: user.head_seq,
        # The oldest changelog entry still retained. If a client's cursor is below this,
        # the entries it needs were pruned — it must fall back to a full snapshot
        # (`SyncEngine::pull_changes` detects the gap and resyncs).
        #
        # When the table is EMPTY (a full prune: keep_after >= head_seq), report head_seq + 1,
        # NOT 0. Reporting 0 reads to the client as "nothing pruned", so a behind cursor would
        # silently fast-forward past the pruned entries and diverge. head_seq + 1 sits strictly
        # above any behind cursor, so the gap is detected and the device full-resyncs.
        oldest_seq: user.changelog_entries.minimum(:seq) || (user.head_seq + 1)
      }
    end

    def self.serialize(entry, nodes, versions, manifests)
      out = { seq: entry.seq, op: entry.op, node_id: entry.node_id }
      node = nodes[entry.node_id]
      if node
        out[:node] = {
          node_id: node.node_id, parent_node_id: node.parent_node_id,
          name: node.name, kind: node.kind, deleted: node.deleted, mode: node.mode, mtime: node.mtime
        }
        # A symlink carries its target (its whole content) on the node, base64'd so a
        # non-UTF8 path survives JSON. The client decodes it back to the link bytes.
        out[:node][:symlink_target] = Base64.strict_encode64(node.symlink_target) if node.symlink? && node.symlink_target
      end
      if entry.op == "put" && entry.version_id.present?
        version = versions[entry.version_id]
        if version
          out[:version] = { version_id: version.version_id, manifest_id: version.manifest_id, size: version.size }
          out[:manifest] = manifests.fetch(version.manifest_id, [])
        end
      end
      out
    end
  end
end
