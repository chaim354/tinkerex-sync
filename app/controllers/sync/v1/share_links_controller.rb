module V1
  # Authenticated management of read-only share links (the owner side). Creating a link
  # requires owning the target version; revoking requires owning the link. The anonymous
  # redeem side lives in the bearer-less ShareController.
  class ShareLinksController < BaseController
    # GATED ON ITS BEHAVIOR, NOT ITS NAME -- and the distinction matters here more than anywhere
    # else in this API. "Share" in THIS file means a public link to a file; FileLayer::Share means
    # a mounted directory backing the library. They are unrelated, and gating this because the two
    # words collide would be the naming trap, not a decision.
    #
    # The decision is that a share link is VERSION-scoped by construction: create_for_version! is
    # `user.versions.find_by!`, and the link freezes that version's manifest_id so it stays a
    # stable snapshot after an overwrite. A current-state-only library has no version to freeze, so
    # no link can be minted -- or, therefore, revoked. Ungated, #create answered 404 "not_found"
    # for a version that cannot exist, which reads as "wrong id, try another" and invites a retry
    # forever; the client could not even have obtained a version_id, since #versions now answers
    # 501. Current-state share links would be a feature, and this gate is where it would land.
    #
    # The ANONYMOUS redeem side (V1::ShareController) is deliberately NOT gated: see its header.
    require_capability! :versioned

    # POST /v1/share_links { node_id, version_id, expires_at? } -> { id, token } (token once)
    def create
      link = Sync::Sharing::Links.create_for_version!(
        user: current_user,
        node_id: params.require(:node_id),
        version_id: params.require(:version_id),
        expires_at: params[:expires_at]
      )
      render json: { id: link.id, token: link.raw_token, version_id: link.version_id,
                     expires_at: link.expires_at }, status: :created
    end

    # DELETE /v1/share_links/:id -> revoke. Scoped to the caller's own links, so another
    # user's link id resolves to RecordNotFound (404) rather than leaking its existence.
    def destroy
      link = current_user.share_links.find(params[:id])
      Sync::Sharing::Links.revoke!(link)
      head :no_content
    end
  end
end
