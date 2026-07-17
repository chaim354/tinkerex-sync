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
      manifest = ManifestChunk
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
    def stash_request_base_url
      if Storage::ChunkStore.current.is_a?(Storage::LocalChunkStore)
        Storage::LocalChunkStore::PUBLIC_URL_OVERRIDE.value = request.base_url
      end
    end
  end
end
