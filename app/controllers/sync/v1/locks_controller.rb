module Sync
  module V1
    class LocksController < BaseController
      # Best-effort locks coordinate DEVICES editing through a mount. A share/s3 library has no
      # devices, and the user's own Finder/S3-console writes are not something we could lock anyway.
      require_capability! :syncable

      # GET /v1/locks -> all active edit locks (for the file browser's lock indicators).
      # Passes current_device so each lock's by_me reflects THIS caller -- omitting it (as this
      # used to) makes Locks.active default by_me to false for every lock, even the caller's own.
      def index
        render json: { locks: Sync::Locks.active(user: current_user, device: current_device) }
      end
    end
  end
end
