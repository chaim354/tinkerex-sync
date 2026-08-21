module V1
  class LocksController < BaseController
    # Best-effort locks coordinate DEVICES editing through a mount. A share/s3 library has no
    # devices, and the user's own Finder/S3-console writes are not something we could lock anyway.
    require_capability! :syncable

    # GET /v1/locks -> all active edit locks (for the file browser's lock indicators).
    def index
      render json: { locks: Sync::Locks.active(user: current_user) }
    end
  end
end
