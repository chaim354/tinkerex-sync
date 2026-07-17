module V1
  class ConflictsController < BaseController
    # A conflict is two devices' divergent versions of one node. Without sync there is neither
    # side, and an empty list here would say "no conflicts" -- the same shape of lie as #versions.
    require_capability! :syncable

    # GET /v1/conflicts -> unresolved conflicts with both sides' device/time/size, for
    # the "which version is current?" prompt.
    def index
      render json: { conflicts: Sync::Conflicts.list(user: current_user) }
    end
  end
end
