# Not exercised by any test moved into this suite (the one Sync::LibraryChannel test asserts
# against `broadcast_to` directly, never a live connection) -- included anyway, byte-identical to
# the host's app/channels/application_cable/connection.rb, so that a real WS client could
# actually authenticate against this dummy the same way it would against the real host. Device is
# the same dummy stand-in every other engine test in this suite already depends on.
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      device = Device.authenticate(request.params[:token])
      reject_unauthorized_connection unless device
      self.current_user = device.user
    end
  end
end
