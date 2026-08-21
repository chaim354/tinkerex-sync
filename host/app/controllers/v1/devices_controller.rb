# frozen_string_literal: true

module V1
  # DEVICE ENROLMENT, AND THERE IS DELIBERATELY NO PASSWORD LOGIN HERE.
  #
  # chaim354/tinkerex's own DevicesController has one (`POST /v1/devices/login`, email + password)
  # because that app already has users with passwords, sessions and a browser surface. This host has
  # none of those: it is an API with one consumer, and adding a password endpoint would mean
  # inventing a credential scheme -- storage, reset, lockout, rate limiting -- for a server whose
  # whole job is holding chunks.
  #
  # THE FIRST TOKEN IS MINTED BY AN OPERATOR (`bin/rails sync:device:issue`), the same shape as any
  # other server credential. Every device after that can be enrolled by an already-authenticated one
  # through `#create` below, which is how a fleet grows without a password ever existing.
  #
  # If this host ever does need self-service enrolment, the answer is the one CLAUDE.md §12 item 1
  # already names for the maker app -- real OAuth/OIDC -- not a hand-rolled password field.
  class DevicesController < BaseController
    def create
      device = Device.register!(user: current_user, name: params[:name].presence || "device")
      render json: { device_id: device.id, device_token: device.plaintext_token }, status: :created
    end

    # Lets a client confirm which user and how far ahead the server is, without guessing from a
    # changelog pull. The maker app's ChangelogSync does not need it; a human debugging a token does.
    def whoami
      render json: { user_id: current_user.id, device_id: current_device.id,
                     head_seq: current_user.head_seq }
    end
  end
end
