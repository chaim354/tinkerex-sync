module V1
  # Authenticated management of read-only share links (the owner side). Creating a link
  # requires owning the target version; revoking requires owning the link. The anonymous
  # redeem side lives in the bearer-less ShareController.
  class ShareLinksController < BaseController
    # POST /v1/share_links { node_id, version_id, expires_at? } -> { id, token } (token once)
    def create
      link = Sharing::Links.create_for_version!(
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
      Sharing::Links.revoke!(link)
      head :no_content
    end
  end
end
