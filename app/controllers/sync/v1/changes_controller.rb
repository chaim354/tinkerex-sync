module V1
  class ChangesController < BaseController
    # The changelog IS the sync engine (spec §3.3 mounts this surface only in chunk mode). A
    # share- or s3-backed library's catalog comes from scanning the store, so there is no
    # changelog to page through and never will be.
    require_capability! :syncable

    # GET /v1/changes?since=<seq>&limit=<n>
    def index
      data = Sync::Changes.call(
        user: current_user,
        since: params.fetch(:since, 0).to_i,
        limit: (params[:limit] || 500).to_i.clamp(1, 2000)
      )
      render json: data
    end
  end
end
