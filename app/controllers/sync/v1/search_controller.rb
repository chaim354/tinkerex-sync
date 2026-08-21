module Sync
  module V1
    class SearchController < BaseController
      # GET /v1/search?q=<query>&limit=<n>&offset=<n>&include_deleted=<bool>
      #
      # Name/path substring search over the device's user's tree (tenant = user). Returns
      # matching nodes with their full path, kind, and (for files) size. Tombstoned nodes are
      # excluded unless include_deleted=true (trash search). Paginated like tree/changes.
      def index
        data = Sync::Search.call(
          user: current_user,
          query: params[:q].to_s,
          include_deleted: ActiveModel::Type::Boolean.new.cast(params[:include_deleted]) || false,
          limit: (params[:limit] || Sync::Search::MAX_LIMIT).to_i,
          offset: (params[:offset] || 0).to_i
        )
        render json: data
      end
    end
  end
end
