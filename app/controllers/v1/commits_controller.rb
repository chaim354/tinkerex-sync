module V1
  class CommitsController < BaseController
    # The two-phase content commit: the sync engine's write path, chunks and all.
    require_capability! :syncable

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
    # ON by default. `finalize_verification.rb` is `ENV.fetch("SYNC_VERIFY_FINALIZE", "1") == "1"`,
    # and the sync-engine suites are what set it to 0 (their bytes move through SharedDirIO, so
    # the server's own store cannot see them). This line said "Off by default" until 2026-08-19 —
    # wrong, contradicted by the initializer AND by the sentence three lines above it, and a
    # reader who believed it would conclude production mints immutable versions without ever
    # checking the bytes landed.
    def finalize
      version, seq = Sync::Commit.finalize(user: current_user, commit_id: params[:commit_id],
                                           verify: Rails.configuration.x.verify_finalize)
      LibraryChannel.broadcast_change(current_user, seq)
      # Eagerly render a thumbnail for a file synced from the desktop/API client (not just web
      # uploads). content_token == version_id in chunk mode; best-effort, never fails the commit.
      node = current_user.nodes.find_by(node_id: version.node_id)
      if node
        ::Maker::Previews::Enqueue.call(user: current_user, node_id: version.node_id,
                                        name: node.name, version_id: version.version_id)
        # And file it, if it landed at a project folder's root — closing §12.10's "a device push
        # gets no eager nudge". Deliberately HERE rather than in Sync::Commit#finalize: a controller
        # is the top layer and already reaches into Maker:: for the preview above, whereas a maker
        # call inside Sync::Commit would invert the layering (the sync engine is what the maker
        # layer is built ON). See .nudge for why this is an async, deduplicated enqueue rather than
        # the synchronous sweep §12.10 rejected.
        ::Maker::ProjectIntakeJob.nudge(user: current_user, node:)
      end
      render json: { version_id: version.version_id, seq: }
    rescue Sync::Commit::ChunksMissing => e
      render json: { error: "chunks_missing", missing: e.hashes }, status: :unprocessable_entity
    end
  end
end
