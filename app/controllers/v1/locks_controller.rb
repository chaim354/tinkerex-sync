module V1
  class LocksController < BaseController
    # GET /v1/locks -> all active edit locks (for the file browser's lock indicators).
    def index
      render json: { locks: Sync::Locks.active(user: current_user) }
    end
  end
end
