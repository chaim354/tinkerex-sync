module V1
  class NodesController < BaseController
    # POST /v1/nodes  (mkdir)  { node_id, parent_node_id, name }
    def mkdir
      node = current_user.nodes.find_or_initialize_by(node_id: params.require(:node_id))
      node.assign_attributes(
        parent_node_id: params[:parent_node_id], name: params.require(:name),
        kind: "dir", deleted: false
      )
      seq = Sync::Mutation.apply(user: current_user, node:, op: "mkdir")
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
  end
end
