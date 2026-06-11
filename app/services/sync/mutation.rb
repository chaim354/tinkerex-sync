module Sync
  # Every change to the tree funnels through here so the invariant always holds:
  # one atomic transaction that (a) mutates the node, (b) assigns the next per-user
  # changelog seq, (c) stamps the node, (d) appends exactly one changelog entry.
  #
  # Used by the metadata ops (mkdir/delete/move/restore). Content commits do the
  # same inline in Sync::Commit (they have extra work in the same transaction).
  class Mutation
    def self.apply(user:, node:, op:, version_id: nil)
      seq = nil
      ApplicationRecord.transaction do
        yield(node) if block_given?
        seq = user.next_seq!
        node.updated_seq = seq
        node.save!
        user.changelog_entries.create!(
          seq:, node_id: node.node_id, op:, version_id:, created_at: Time.current
        )
      end
      seq
    end
  end
end
