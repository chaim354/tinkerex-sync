module V1
  class NodesController < BaseController
    # POST /v1/nodes  (mkdir)  { node_id, parent_node_id, name }
    def mkdir
      node = current_user.nodes.find_or_initialize_by(node_id: params.require(:node_id))
      node.assign_attributes(
        parent_node_id: params[:parent_node_id], name: params.require(:name),
        kind: "dir", deleted: false, mode: params[:mode] || node.mode || 0o755,
        mtime: params[:mtime] || node.mtime
      )
      seq = Sync::Mutation.apply(user: current_user, node:, op: "mkdir")
      LibraryChannel.broadcast_change(current_user, seq)
      render json: { node_id: node.node_id, seq: }, status: :created
    end

    # POST /v1/nodes/symlink  { node_id, parent_node_id, name, symlink_target, mode, mtime }
    # Create/update a symlink node. The link target is base64-encoded (it's raw path bytes,
    # possibly non-UTF8) and stored inline on the node — a symlink has no version/manifest,
    # so it's a single metadata mutation (like mkdir), op "symlink".
    def symlink
      node = current_user.nodes.find_or_initialize_by(node_id: params.require(:node_id))
      target = params[:symlink_target].present? ? Base64.strict_decode64(params[:symlink_target]) : nil
      node.assign_attributes(
        parent_node_id: params[:parent_node_id], name: params.require(:name),
        kind: "symlink", deleted: false, symlink_target: target,
        mode: params[:mode] || node.mode || 0o777,
        mtime: params[:mtime] || node.mtime
      )
      seq = Sync::Mutation.apply(user: current_user, node:, op: "symlink")
      LibraryChannel.broadcast_change(current_user, seq)
      render json: { node_id: node.node_id, seq: }, status: :created
    end

    # DELETE /v1/nodes/:node_id   (tombstone; versions retained for restore)
    def destroy
      node = current_user.nodes.find_by!(node_id: params[:node_id])
      seq = Sync::Mutation.apply(user: current_user, node:, op: "delete") { |n| n.deleted = true }
      LibraryChannel.broadcast_change(current_user, seq)
      render json: { seq: }
    end

    # POST /v1/nodes/:node_id/move   { new_parent_node_id, new_name }
    def move
      node = current_user.nodes.find_by!(node_id: params[:node_id])
      seq = Sync::Mutation.apply(user: current_user, node:, op: "move") do |n|
        n.parent_node_id = params[:new_parent_node_id] if params.key?(:new_parent_node_id)
        n.name = params[:new_name] if params[:new_name].present?
      end
      LibraryChannel.broadcast_change(current_user, seq)
      render json: { seq: }
    end

    # GET /v1/nodes/:node_id/versions
    def versions
      node = current_user.nodes.find_by!(node_id: params[:node_id])
      vs = current_user.versions.where(node_id: node.node_id).order(id: :desc).limit(200)
      render json: {
        versions: vs.map { |v|
          { version_id: v.version_id, manifest_id: v.manifest_id, size: v.size,
            parent_version_id: v.parent_version_id, created_at: v.created_at }
        }
      }
    end

    # POST /v1/nodes/:node_id/restore   { version_id }
    def restore
      version, seq = Sync::Restore.call(
        user: current_user, node_id: params[:node_id], version_id: params.require(:version_id)
      )
      LibraryChannel.broadcast_change(current_user, seq)
      render json: { version_id: version.version_id, seq: }
    end

    # POST /v1/nodes/:node_id/lock — best-effort acquire/refresh. Always 200 with the
    # status (held + by_me + device_name); the client decides what to do if not by_me.
    def lock
      render json: Sync::Locks.acquire(user: current_user, node_id: params[:node_id], device: current_device)
    end

    # POST /v1/nodes/:node_id/unlock — release if this device holds it.
    def unlock
      Sync::Locks.release(user: current_user, node_id: params[:node_id], device: current_device)
      render json: { released: true }
    end

    # POST /v1/nodes/:node_id/resolve_conflict
    #   { keep_version_id }  -> keep one side as current (the other stays in history)
    #   { split: true }      -> keep both (incoming becomes a new sibling file)
    def resolve_conflict
      if ActiveModel::Type::Boolean.new.cast(params[:split])
        # N-way: a node may have several divergent incoming versions; split makes a sibling for
        # each. `split_node_id` stays for 2-way callers; `split_node_ids` lists every new sibling.
        new_node_id, seq, new_node_ids = Sync::Conflicts.split(user: current_user, node_id: params[:node_id])
        LibraryChannel.broadcast_change(current_user, seq)
        render json: { split_node_id: new_node_id, split_node_ids: new_node_ids, seq: }
      else
        seq = Sync::Conflicts.keep(
          user: current_user, node_id: params[:node_id], version_id: params.require(:keep_version_id)
        )
        LibraryChannel.broadcast_change(current_user, seq)
        render json: { seq: }
      end
    end
  end
end
