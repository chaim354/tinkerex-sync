module Sync
  module V1
    # Trash / undelete API (deleted-file recovery). Deletes are tombstones + versions are
    # kept, so this is purely surfacing recovery: list tombstoned nodes and un-tombstone
    # one (re-pointing at its existing current version — no new chunks).
    class TrashController < BaseController
      # TWO DIFFERENT FEATURES SHARE THE WORD "TRASH", AND THIS IS THE CHUNK ONE. Here a delete is
      # a tombstone whose versions are kept, so restore just re-points the node at a version it
      # still has. A share/s3 library's trash is a different mechanism entirely (2b: the bytes are
      # moved to `.trash/<node_id>/<name>` and recovered through FileLayer#undelete), and running
      # THIS restore against one would un-tombstone a node with no version to re-point at:
      #   - a SCAN tombstone (the file vanished from the NAS) comes back live, and the next scan
      #     tombstones it again;
      #   - a TRASH tombstone (storage_path NULLed, 2b) comes back live pointing at nothing, while
      #     its bytes sit in `.trash` awaiting an undelete that now has a live node in its way.
      # Neither is a recovery. 501 says this deployment does not have THIS trash; exposing the
      # share trash over v1 is a feature, not a gate, and is not this phase's.
      require_capability! :syncable

      # GET /v1/trash — the user's tombstoned nodes (newest-deleted first).
      #
      # THE SIZES COME FROM ONE BATCH LOAD, NOT `n.current_version` PER ROW. This list is unbounded —
      # `FileLayer::Chunk#trashed`, which serves the same rows through the port, says so in its own
      # comment ("it is every file the user ever deleted") — and there is no pagination here. Each
      # `Node#current_version` is a `find_by` (no AR association on the string `version_id`, so
      # `includes` cannot reach it), so the loop cost 4 + N queries, N being the tombstones that
      # carry a `current_version_id`. Measured on this endpoint: N=1 → 5, N=5 → 9, N=25 → 29; now a
      # constant 5. The web `trash#index` was batched and budget-guarded from the start; this one
      # was neither.
      #
      # `.to_a` MATERIALIZES ONCE, AND SAVES NO QUERY — do not document it as one. An earlier
      # version of this comment claimed the `filter_map` and the `map` were two executions of the
      # tombstone query. They are not: `nodes` is a single relation, `filter_map` loads and memoizes
      # it (`loaded?` is true afterwards), and the relation form measures identically — 5 queries at
      # N=1/5/25, probed. What `.to_a` buys is that `nodes` is unambiguously an Array for both
      # enumerations, so a later edit replacing it with a second `Sync::Trash.list(...)` call cannot
      # silently reintroduce the second query. That is its whole claim.
      def index
        nodes = Sync::Trash.list(user: current_user).to_a
        sizes = Sync.load_version_sizes(current_user, nodes.filter_map(&:current_version_id))
        render json: {
          items: nodes.map { |n|
            { node_id: n.node_id, name: n.name, kind: n.kind,
              parent_node_id: n.parent_node_id, deleted_at: n.updated_at,
              size: sizes[n.current_version_id], version_id: n.current_version_id }
          }
        }
      end

      # POST /v1/trash/:node_id/restore  { to_root? }
      # Un-tombstones the node and appends a `put` changelog entry so other devices
      # converge. If the parent is itself deleted, returns 409 unless to_root=true.
      def restore
        to_root = ActiveModel::Type::Boolean.new.cast(params[:to_root])
        node, seq = Sync::Trash.restore(user: current_user, node_id: params[:node_id], to_root:)
        Sync::LibraryChannel.broadcast_change(current_user, seq) if seq
        render json: { node_id: node.node_id, parent_node_id: node.parent_node_id, seq: }
      rescue Sync::Trash::ParentDeleted
        render json: { error: "parent_deleted" }, status: :conflict
      end
    end
  end
end
