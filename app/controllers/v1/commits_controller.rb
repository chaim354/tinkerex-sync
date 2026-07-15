module V1
  class CommitsController < BaseController
    # POST /v1/commit
    # body: { commit_id, node_id, parent_node_id, name, base_version_id, size,
    #         manifest: [{ hash, offset, length }, ...] }
    def create
      p = params.permit(:commit_id, :node_id, :parent_node_id, :name, :base_version_id,
                        :size, :mode, :mtime, manifest: %i[hash offset length])
      result = Sync::Commit.begin(
        user: current_user, device: current_device,
        commit_id: p[:commit_id], node_id: p[:node_id], parent_node_id: p[:parent_node_id],
        name: p[:name], base_version_id: p[:base_version_id], size: p[:size], mode: p[:mode],
        mtime: p[:mtime], manifest: (p[:manifest] || []).map(&:to_h)
      )
      render json: { commit_id: result.commit_id, missing: result.missing, put_urls: result.put_urls }
    end

    # POST /v1/commit/:commit_id/finalize
    # When config.x.verify_finalize is on (SYNC_VERIFY_FINALIZE=1; recommended in production),
    # confirm the chunk bytes actually landed in storage (a cheap exists?-check for first-seen
    # hashes only) before creating the immutable version + changelog entry — so a client that
    # crashes/lies between PUT and finalize can't create a version + chunk rows for bytes that
    # never arrived (permanent hydration 404s; dedup then reports the phantom chunk "present").
    # Off by default (see config/initializers/finalize_verification.rb for why).
    def finalize
      version, seq = Sync::Commit.finalize(user: current_user, commit_id: params[:commit_id],
                                           verify: Rails.configuration.x.verify_finalize)
      LibraryChannel.broadcast_change(current_user, seq)
      render json: { version_id: version.version_id, seq: }
    rescue Sync::Commit::ChunksMissing => e
      render json: { error: "chunks_missing", missing: e.hashes }, status: :unprocessable_entity
    end
  end
end
