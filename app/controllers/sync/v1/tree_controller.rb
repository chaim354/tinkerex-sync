module Sync
  module V1
    class TreeController < BaseController
      # The initial-sync snapshot a device pairs with. Nothing syncs a share/s3 library.
      require_capability! :syncable

      # GET /v1/tree?after_id=<id>&limit=<n>  (initial-sync snapshot, paginated)
      def index
        data = Sync::Tree.call(
          user: current_user,
          after_id: params.fetch(:after_id, 0).to_i,
          limit: (params[:limit] || 1000).to_i.clamp(1, 5000)
        )
        render json: data
      end
    end
  end
end
