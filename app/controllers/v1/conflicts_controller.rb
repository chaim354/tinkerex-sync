module V1
  class ConflictsController < BaseController
    # GET /v1/conflicts -> unresolved conflicts with both sides' device/time/size, for
    # the "which version is current?" prompt.
    def index
      render json: { conflicts: Sync::Conflicts.list(user: current_user) }
    end
  end
end
