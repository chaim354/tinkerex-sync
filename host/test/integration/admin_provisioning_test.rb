# frozen_string_literal: true

require "test_helper"

# PROVES THE REAL WIRING, NOT JUST test/dummy'S. The engine's own
# test/integration/v1/admin_libraries_test.rb already covers this endpoint's logic exhaustively
# (all three refusal shapes, the create/idempotency pair, digest-only token storage) against
# test/dummy -- which shares byte-identical User/Device stand-ins with this host, so there is
# nothing left for a full re-test here to prove about the LOGIC. What only a test running inside
# THIS app can prove is that SYNC_ADMIN_TOKEN, read from plain ENV, genuinely reaches
# Sync::V1::Admin::LibrariesController through the real host/config/routes.rb -> Sync.draw_v1_routes
# path, in an ordinary Rails integration test -- the same "two apps, two questions" reasoning
# device_journey_test.rb states for itself. conformance/scenarios/11-admin.yml already proves the
# wire shape against this same real app booted as a separate process; this is the cheaper,
# in-process belt-and-suspenders check for the one thing that differs between here and test/dummy:
# real ENV, not a test double.
class AdminProvisioningTest < ActionDispatch::IntegrationTest
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

  test "an unset SYNC_ADMIN_TOKEN refuses the endpoint in the real host, not just test/dummy" do
    with_admin_token(nil) do
      post "/v1/admin/libraries", params: { email: "host-noauth@example.com" }, as: :json
      assert_response :service_unavailable
    end
  end

  test "a real device token from THIS host cannot provision a library" do
    with_admin_token("host-admin-fixture") do
      user = User.create!(email: "host-device-owner@example.com")
      device = Device.register!(user:, name: "laptop")

      post "/v1/admin/libraries", params: { email: "host-escalation@example.com" }, as: :json,
                                   headers: { "Authorization" => "Bearer #{device.plaintext_token}" }
      assert_response :unauthorized
      assert_not User.exists?(email: "host-escalation@example.com")
    end
  end

  test "a valid admin token provisions a library through the real host, and the token authenticates" do
    with_admin_token("host-admin-fixture") do
      post "/v1/admin/libraries", params: { email: "host-provisioned@example.com" }, as: :json,
                                   headers: { "Authorization" => "Bearer host-admin-fixture" }
      assert_response :created
      body = JSON.parse(response.body)

      # The device this endpoint minted authenticates against the SAME v1 surface a maker app
      # (chunk_remote) or a desktop client would use -- proven through host-only whoami, which
      # test/dummy does not even draw.
      get "/v1/devices/whoami", headers: { "Authorization" => "Bearer #{body['device_token']}" }
      assert_response :success
      assert_equal body["user_id"], JSON.parse(response.body)["user_id"]
    end
  end
end
