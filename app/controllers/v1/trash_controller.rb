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
    def index
      nodes = Sync::Trash.list(user: current_user)
      render json: {
        items: nodes.map { |n|
          v = n.current_version
          { node_id: n.node_id, name: n.name, kind: n.kind,
            parent_node_id: n.parent_node_id, deleted_at: n.updated_at,
            size: v&.size, version_id: n.current_version_id }
        }
      }
    end

    # POST /v1/trash/:node_id/restore  { to_root? }
    # Un-tombstones the node and appends a `put` changelog entry so other devices
    # converge. If the parent is itself deleted, returns 409 unless to_root=true.
    def restore
      to_root = ActiveModel::Type::Boolean.new.cast(params[:to_root])
      node, seq = Sync::Trash.restore(user: current_user, node_id: params[:node_id], to_root:)
      LibraryChannel.broadcast_change(current_user, seq) if seq
      render json: { node_id: node.node_id, parent_node_id: node.parent_node_id, seq: }
    rescue Sync::Trash::ParentDeleted
      render json: { error: "parent_deleted" }, status: :conflict
    end
  end
end
