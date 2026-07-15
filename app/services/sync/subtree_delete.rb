module Sync
  # Tombstone a node AND its whole present subtree in one transaction.
  #
  # Deleting a directory must not leave its descendants `present`: the /v1/tree snapshot
  # serves `user.nodes.present`, so a device onboarding via the snapshot would otherwise get
  # orphaned children pointing at a deleted parent, while a device following the changelog
  # deletes the whole subtree client-side (apply_remote_delete is recursive) — the two views
  # would diverge. Cascading the tombstone server-side keeps them consistent.
  #
  # Each affected node gets its OWN changelog seq + `delete` entry (one mutation per node, the
  # standard changelog shape the client already applies), minted under the user-row lock like
  # every other mutation (next_seq! FIRST — see Sync::Commit#finalize). Returns the last seq.
  class SubtreeDelete
    def self.call(user:, node:)
      last_seq = nil
      ApplicationRecord.transaction do
        # Lock the user row + take the first seq BEFORE any node/changelog write (FK-deadlock
        # avoidance — see Sync::Commit#finalize). Collect the subtree under the lock so a
        # concurrent add can't slip a child in after we've enumerated.
        first_seq = user.next_seq!
        targets = collect(user, node)
        targets.each_with_index do |n, i|
          seq = i.zero? ? first_seq : user.next_seq!
          n.deleted = true
          n.updated_seq = seq
          n.save!
          user.changelog_entries.create!(
            seq:, node_id: n.node_id, op: "delete", created_at: Time.current
          )
          last_seq = seq
        end
      end
      last_seq
    end

    # The root node plus every present descendant, BFS over parent_node_id. A `seen` set bounds
    # the walk even if the stored tree has a cycle (the move/mkdir guard prevents new ones).
    def self.collect(user, root)
      targets = [ root ]
      seen = { root.node_id => true }
      frontier = [ root.node_id ]
      until frontier.empty?
        children = user.nodes.present.where(parent_node_id: frontier)
                       .where.not(node_id: seen.keys).to_a
        break if children.empty?
        children.each { |c| seen[c.node_id] = true }
        targets.concat(children)
        frontier = children.map(&:node_id)
      end
      targets
    end
  end
end
