require "test_helper"

module V1
  # POST /v1/admin/libraries -- provisioning, gated by a credential no device ever holds.
  #
  # EVERY TEST HERE SETS ENV["SYNC_ADMIN_TOKEN"] ITSELF, RATHER THAN RELYING ON AN AMBIENT VALUE,
  # and restores it in an `ensure` -- the same discipline `tenant_isolation_test.rb`'s neighbours
  # use for `LIBRARY_BACKEND` in the maker repo (per this file's own comment lineage), applied to a
  # value that must never leak between tests: a test that left SYNC_ADMIN_TOKEN set would make a
  # LATER test's "unset must refuse" assertion pass for the wrong reason.
  class AdminLibrariesTest < ActionDispatch::IntegrationTest
    def with_admin_token(value)
      prior = ENV["SYNC_ADMIN_TOKEN"]
      ENV["SYNC_ADMIN_TOKEN"] = value
      yield
    ensure
      if prior.nil?
        ENV.delete("SYNC_ADMIN_TOKEN")
      else
        ENV["SYNC_ADMIN_TOKEN"] = prior
      end
    end

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    test "an unset SYNC_ADMIN_TOKEN refuses the endpoint, not the whole boot" do
      with_admin_token(nil) do
        post "/v1/admin/libraries", params: { email: "nope@example.com" }, as: :json,
                                     headers: auth("anything")
        assert_response :service_unavailable
        assert_equal "admin_provisioning_disabled", JSON.parse(response.body)["error"]
      end
    end

    test "a SYNC_ADMIN_TOKEN blanked to an empty string (Kamal's env.clear shape) refuses the same way as unset" do
      # Kamal's `env.clear` blanks a variable rather than removing it (documented behaviour this
      # codebase relies on elsewhere -- e.g. ADDON_SOURCE_URL / the *_SIDECAR_URL family in the
      # sibling monorepo). ENV["X"] = "" is a DIFFERENT Ruby value from ENV["X"] being absent, and
      # a check that only tested `.nil?` would treat a blanked-but-present token as configured.
      with_admin_token("") do
        post "/v1/admin/libraries", params: { email: "nope2@example.com" }, as: :json,
                                     headers: auth("anything")
        assert_response :service_unavailable
      end
    end

    test "no Authorization header at all is refused" do
      with_admin_token("s3cr3t-admin") do
        post "/v1/admin/libraries", params: { email: "noauth@example.com" }, as: :json
        assert_response :unauthorized
        assert_equal "unauthorized", JSON.parse(response.body)["error"]
      end
    end

    test "the wrong token is refused" do
      with_admin_token("s3cr3t-admin") do
        post "/v1/admin/libraries", params: { email: "wrong@example.com" }, as: :json,
                                     headers: auth("not-the-admin-token")
        assert_response :unauthorized
      end
    end

    test "a valid DEVICE token is refused as an admin token -- the two credentials are not interchangeable" do
      with_admin_token("s3cr3t-admin") do
        device_token = bootstrap_token(email: "ordinary-device-user@example.com")
        post "/v1/admin/libraries", params: { email: "escalation-attempt@example.com" }, as: :json,
                                     headers: auth(device_token)
        assert_response :unauthorized

        # And nothing was provisioned -- a 401 here must not be a 401 with a side effect.
        assert_not User.exists?(email: "escalation-attempt@example.com")
      end
    end

    test "a valid admin token provisions a User and its first Device" do
      with_admin_token("s3cr3t-admin") do
        assert_difference -> { User.count }, 1 do
          assert_difference -> { Device.count }, 1 do
            post "/v1/admin/libraries", params: { email: "fresh-library@example.com", name: "laptop" },
                                         as: :json, headers: auth("s3cr3t-admin")
          end
        end
        assert_response :created

        body = JSON.parse(response.body)
        assert_equal %w[device_id device_token user_id], body.keys.sort
        assert_kind_of Integer, body["user_id"]
        assert_kind_of Integer, body["device_id"]
        assert_kind_of String, body["device_token"]

        user = User.find(body["user_id"])
        assert_equal "fresh-library@example.com", user.email
        device = Device.find(body["device_id"])
        assert_equal user.id, device.user_id
        assert_equal "laptop", device.name

        # The token is shown once and only its digest is stored -- the same contract
        # sync:device:issue documents for itself. The response's plaintext token must authenticate
        # against the engine's own auth (Device.authenticate) -- proven via an ENGINE route
        # (/v1/devices/whoami is host-only, drawn by host/config/routes.rb, not by
        # Sync.draw_v1_routes, so it does not exist in this test's process at all).
        get "/v1/tree", headers: auth(body["device_token"])
        assert_response :success
        # ...but the raw value must not be sitting in the row a caller with DB access could read.
        assert_not_equal body["device_token"], device.token_digest
        assert_equal Device.digest(body["device_token"]), device.token_digest
      end
    end

    test "a device name defaults the same way POST /v1/devices does when none is given" do
      with_admin_token("s3cr3t-admin") do
        post "/v1/admin/libraries", params: { email: "no-name-given@example.com" }, as: :json,
                                     headers: auth("s3cr3t-admin")
        assert_response :created
        device = Device.find(JSON.parse(response.body)["device_id"])
        assert_equal "device", device.name
      end
    end

    test "a repeat call for the same email refuses rather than minting a second device onto the existing library" do
      with_admin_token("s3cr3t-admin") do
        post "/v1/admin/libraries", params: { email: "repeat@example.com" }, as: :json,
                                     headers: auth("s3cr3t-admin")
        assert_response :created
        first_device_id = JSON.parse(response.body)["device_id"]

        assert_no_difference -> { User.count } do
          assert_no_difference -> { Device.count } do
            post "/v1/admin/libraries", params: { email: "repeat@example.com" }, as: :json,
                                         headers: auth("s3cr3t-admin")
          end
        end
        assert_response :conflict
        assert_equal "email_taken", JSON.parse(response.body)["error"]

        # The original device is untouched -- no new credential was minted for anyone to have
        # silently received.
        assert Device.exists?(first_device_id)
        assert_equal 1, User.find_by!(email: "repeat@example.com").devices.count
      end
    end

    test "a missing email is a 400, not a 500" do
      with_admin_token("s3cr3t-admin") do
        post "/v1/admin/libraries", params: {}, as: :json, headers: auth("s3cr3t-admin")
        assert_response :bad_request
      end
    end

    test "an unauthenticated request is refused before ever touching the database" do
      with_admin_token("s3cr3t-admin") do
        assert_no_difference -> { User.count } do
          post "/v1/admin/libraries", params: { email: "never-created@example.com" }, as: :json,
                                       headers: auth("wrong")
        end
        assert_not User.exists?(email: "never-created@example.com")
      end
    end
  end
end
