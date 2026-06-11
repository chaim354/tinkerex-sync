# Bearer device-token auth. Placeholder for v1 — real OAuth/OIDC is a later
# workstream; the token mechanism (per-device secret, only the digest stored) is
# the part that stays.
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
