# Bearer device-token auth. Placeholder for v1 — real OAuth/OIDC is a later
# workstream; the token mechanism (per-device secret, only the digest stored) is
# the part that stays.
#
# MOVED HERE FROM app/controllers/concerns/authentication.rb AS PART OF Stage 3b Phase B Task 7's
# V1::BaseController split, EVEN THOUGH IT WAS NEVER LISTED IN SYNC_SIDE_GLOBS -- the plan's own
# premises section says that list is "a scanning convenience, NOT a correct 'what moves' list",
# and this is a second instance of the same correction Phase A's Task 1 made for
# app/services/storage/**: read the file, not the glob. `Device.authenticate` is the sync
# engine's own credential (CLAUDE.md §14j: the token is a sync participant's identity, and
# `Device` is already a declared TinkerexSync::HOST_MODELS requirement) -- the fourteen v1/maker/*
# controllers accept it only because they share ONE v1 surface and ONE credential with the sync
# API, not because device-token auth is itself a maker concern. Namespaced under `Sync::V1::`,
# not bare `Sync::`, because it is v1-API-shaped infrastructure specifically (an HTTP
# Authorization header, a JSON 401 body) -- if this engine ever grows a v2 wire format it would
# not automatically inherit this one's rules.
module Sync
  module V1
    module Authentication
      extend ActiveSupport::Concern

      included do
        before_action :authenticate_device!
      end

      private

      def authenticate_device!
        token = request.authorization.to_s.delete_prefix("Bearer ").strip
        @current_device = Device.authenticate(token)
        return render(json: { error: "unauthorized" }, status: :unauthorized) unless @current_device
        @current_user = @current_device.user
        @current_device.touch_seen!
      end

      def current_user = @current_user
      def current_device = @current_device
    end
  end
end
