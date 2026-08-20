module V1
  # The ANONYMOUS redeem side of read-only share links: anyone holding the link token can
  # view the shared version's metadata and mint presigned GET URLs for its chunks. NO device
  # token — the capability token in the URL is the authorization, and it's re-validated
  # (live? + version-scope) on every request. Deliberately does NOT inherit BaseController
  # (which forces device-token auth); it's a bare API controller.
  #
  # Invariants preserved: bytes never flow through Rails (presigned GETs only), the minted
  # URLs are scoped to exactly this version's manifest chunks under the OWNER's keyspace, and
  # a revoked/expired link mints nothing on the next request.
  #
  # NOT capability-gated, while its owner-side counterpart (V1::ShareLinksController) is, and the
  # asymmetry is the decision rather than an oversight. Two reasons, either sufficient:
  #   - The caller here is ANONYMOUS -- the token is the auth. A 501 would tell any stranger
  #     holding any string which backend this deployment runs. 404 tells them what they need to
  #     know, which is nothing.
  #   - The 404 is already honest and already terminal. No link can be minted on an unversioned
  #     deployment (that is the gate on the owner side), so redeem! finds nothing and says so.
  #     "That token isn't valid" is exactly true, in every mode.
  class ShareController < ActionController::API
    rescue_from ActionController::ParameterMissing, with: -> { head :bad_request }
    before_action :stash_request_base_url

    # GET /v1/share/:token -> { name, node_id, version_id, manifest: [{hash, offset, length}] }
    def show
      cap = redeem!
      return not_found unless cap
      node = User.find(cap.owner_id).nodes.find_by(node_id: cap.node_id)
      manifest = Sync::ManifestChunk
                   .where(user_id: cap.owner_id, manifest_id: cap.manifest_id)
                   .order(:seq)
                   .map { |mc| { hash: mc.chunk_hash, offset: mc.offset, length: mc.length } }
      render json: { name: node&.name, node_id: cap.node_id, version_id: cap.version_id,
                     manifest: }
    end

    # POST /v1/share/:token/download -> { urls: { hash => presigned GET } }
    def download
      cap = redeem!
      return not_found unless cap
      render json: { urls: cap.presign_urls }
    end

    private

    def redeem! = Sharing::Links.redeem(params[:token])
    def not_found = render(json: { error: "not_found" }, status: :not_found)

    # Mirror BaseController: for the `local` chunk backend, point presigned blob URLs back at
    # the host the client is talking to when no CHUNK_PUBLIC_URL is configured.
    #
    # INCLUDING ITS GATE, WHICH THIS CONTROLLER NEEDS EVEN MORE THAN THAT ONE DOES: building a
    # chunk store a share deployment never configured raises KeyError, so without this an
    # ANONYMOUS stranger got a Rails 500 page from the endpoint whose whole argument above is
    # that 404 is the honest, backend-disclosing-nothing answer.
    #
    # `versioned`, not `syncable`, because this controller gates itself on the same fact its
    # owner-side counterpart does (V1::ShareLinksController: require_capability! :versioned): a
    # link can only be MINTED where there are versions, so where there are none there is nothing
    # here to presign and redeem! is on its way to 404 regardless.
    #
    # STILL ITS OWN COPY, NOT V1::StashRequestBaseUrl, AND THAT WAS RECONSIDERED AT STAGE 3a
    # TASK 6, NOT OVERLOOKED. That concern's comment used to say the fold-in was "Task 6's to
    # fold in, when share_links moves to the engine side wholesale and there is a natural single
    # home for all three" — reasonable to expect before Task 6 actually ran, because the
    # remaining obstacle looked like directory placement. It wasn't: the concern's gate is
    # HARDCODED to `syncable?`, and this method's gate is `versioned?` for a stated, different
    # reason (a share link needs a `versions` row to exist, not a chunk data plane). Those two
    # capabilities agree on every backend this app has today — chunk true/true, share and s3
    # false/false — but CLAUDE.md §14a spends real space insisting that kind of agreement is
    # three samples, not an identity (`scannable` vs `!syncable?`, `port_writable` vs
    # `scannable`, `dir_deletable` vs `syncable` are each kept separate for exactly this reason).
    # Reusing the concern as-is would silently swap this controller's stated reason for the
    # concern's, which is the coincidence-becomes-bug shape that whole section warns about.
    # Making the concern's gate a parameter instead would touch two already-tested call sites
    # (V1::CommitsController, V1::ChunksController) and their comments to save three lines of
    # duplication here. Judged not clean enough to force; left separate on purpose.
    def stash_request_base_url
      return unless FileLayer.current.capabilities.versioned?
      if Sync::Storage::ChunkStore.current.is_a?(Sync::Storage::LocalChunkStore)
        Sync::Storage::LocalChunkStore::PUBLIC_URL_OVERRIDE.value = request.base_url
      end
    end
  end
end
