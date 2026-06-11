module V1
  class ChangesController < BaseController
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
