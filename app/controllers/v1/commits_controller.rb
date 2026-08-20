module V1
  class CommitsController < BaseController
    # STAGE 3a TASK 5: stash_request_base_url and the two Sync::Commit rescues below used to live
    # on V1::BaseController, which every v1/maker/* controller inherits -- see the comment there
    # for the argument. Both belong here instead: Sync::Commit.begin/.finalize are the only source
    # of InvalidManifest/KindConflict anywhere in this codebase, and #create/#finalize below are
    # their only callers. Covered end-to-end by real HTTP requests, not merely at the service
    # layer: test/integration/v1/node_guards_test.rb's "commit with a traversal chunk hash is
    # rejected (422)" drives InvalidManifest through this exact rescue, and its "committing a file
    # onto an existing dir node is rejected (409)" drives KindConflict through the other.
    include V1::StashRequestBaseUrl
    rescue_from Sync::Commit::InvalidManifest, with: :unprocessable
    # Changing an existing node's kind, or two devices racing to insert the same node_id, is a
    # conflict (409) — a clean, retriable result — not a 500.
    rescue_from Sync::Commit::KindConflict, with: :conflict

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
      Sync::LibraryChannel.broadcast_change(current_user, seq)
      # PUBLISH, DON'T CALL (Stage 3a Task 4). This used to fire ::Maker::Previews::Enqueue and
      # ::Maker::ProjectIntakeJob.nudge directly — the engine reaching into the host's own
      # features, not shared data. See Sync::Hooks for the full argument and its three properties;
      # the host's two subscribers, unchanged in behaviour, now live in
      # config/initializers/sync_hooks.rb.
      #
      # Sync::Commit.finalize's transaction has already committed by this line — its
      # `ApplicationRecord.transaction do…end` closes, and the method returns `[version, seq]`,
      # before this method does anything below it. Firing the hook HERE, rather than from inside
      # that transaction, is what makes Sync::Hooks' property 1 ("after the commit, never inside
      # it") hold; moving this call earlier would break it. Proved in
      # test/integration/v1/commit_finalize_transaction_boundary_test.rb, which fails if the call
      # is moved inside a transaction.
      #
      # `node` can be nil in principle — looked up fresh here rather than reusing anything
      # Sync::Commit.finalize touched internally, unchanged from before this refactor — and
      # neither subscriber can do anything useful without it, so the guard stays at the publish
      # site rather than moving into Sync::Hooks itself.
      node = current_user.nodes.find_by(node_id: version.node_id)
      Sync::Hooks.commit_finalized(user: current_user, node:, version:) if node
      render json: { version_id: version.version_id, seq: }
    rescue Sync::Commit::ChunksMissing => e
      render json: { error: "chunks_missing", missing: e.hashes }, status: :unprocessable_entity
    end
  end
end
