module Sync
  # Trash / undelete (deleted-file recovery).
  #
  # Deletes in this system are TOMBSTONES, not hard deletes (`node.deleted = true`,
  # `Sync::Mutation` op "delete"), and versions are KEPT (never pruned by the delete;
  # GC only sweeps refcount-0 chunks). A tombstoned node still carries its last
  # `current_version_id`. So "undelete" is purely a matter of clearing the tombstone
  # and re-pointing at the version that's already there — NO new chunks, no re-upload.
  #
  # This complements Sync::Restore (which restores a node to a *specific* historical
  # version): Trash.restore brings a *deleted* node back as it was at delete time.
  class Trash
    class ParentDeleted < StandardError; end

    # All tombstoned nodes for a user (the trash), newest-deleted first.
    # `updated_at` is the time of the last mutation, i.e. the tombstone for a deleted
    # node — used as the "deleted-when" timestamp.
    def self.list(user:)
      user.nodes.where(deleted: true).order(updated_at: :desc, name: :asc)
    end

    # Undelete a tombstoned node: clear the tombstone, keep it pointed at its existing
    # current version (the bytes are still there — keep-versions invariant), and append
    # one changelog entry so other devices converge on the restore.
    #
    # Edge case: if the node's parent is itself deleted (or missing), we can't sensibly
    # revive a child into a deleted tree. `to_root: true` re-parents it at the root so
    # it's reachable; otherwise we raise ParentDeleted so the caller can surface the
    # choice clearly.
    def self.restore(user:, node_id:, to_root: false)
      node = user.nodes.find_by!(node_id:)
      return [ node, nil ] unless node.deleted

      orphaned = parent_deleted?(user, node)
      raise ParentDeleted if orphaned && !to_root

      seq = Sync::Mutation.apply(user:, node:, op: "put", version_id: node.current_version_id) do |n|
        n.deleted = false
        n.parent_node_id = nil if orphaned # restore to root when the parent is gone
      end
      [ node, seq ]
    end

    def self.parent_deleted?(user, node)
      return false if node.parent_node_id.blank? # already root-level
      parent = user.nodes.find_by(node_id: node.parent_node_id)
      parent.nil? || parent.deleted
    end
    private_class_method :parent_deleted?
  end
end
