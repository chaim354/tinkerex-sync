require "test_helper"

module V1
  # Tenant = user. The whole security model is ordinary `user_id` scoping, so it must
  # actually hold at the API edge: one user's device token can never see or mutate
  # another user's tree, changelog, or nodes.
  class TenantIsolationTest < ActionDispatch::IntegrationTest
    setup { Storage::ChunkStore.reset! }

    def register(email:)
      post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
      assert_response :created
      JSON.parse(response.body)["device_token"]
    end

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    def commit_file(token, name:, node_id: SecureRandom.uuid)
      cid = SecureRandom.uuid
      chunks = [{ hash: SecureRandom.hex(32), offset: 0, length: 5 }]
      post "/v1/commit",
           params: { commit_id: cid, node_id:, parent_node_id: nil, name:, size: 5, manifest: chunks },
           as: :json, headers: auth(token)
      assert_response :success
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :success
      node_id
    end

    test "a user's tree and changelog never expose another user's nodes" do
      alice = register(email: "alice@example.com")
      bob = register(email: "bob@example.com")
      alice_node = commit_file(alice, name: "secret.stl")

      get "/v1/tree", params: { after_id: 0 }, headers: auth(bob)
      assert_response :success
      bob_tree = JSON.parse(response.body)["nodes"].map { |n| n["node_id"] }
      assert_not_includes bob_tree, alice_node, "Bob must not see Alice's node in tree"

      get "/v1/changes", params: { since: 0 }, headers: auth(bob)
      assert_response :success
      bob_changes = JSON.parse(response.body)["changes"].map { |c| c["node_id"] }
      assert_not_includes bob_changes, alice_node, "Bob must not see Alice's node in changes"
      assert_equal 0, JSON.parse(response.body)["head_seq"], "Bob's library is empty"
    end

    test "a user cannot delete another user's node" do
      alice = register(email: "alice2@example.com")
      bob = register(email: "bob2@example.com")
      alice_node = commit_file(alice, name: "secret.stl")

      delete "/v1/nodes/#{alice_node}", headers: auth(bob)
      assert_response :not_found, "Bob's delete of Alice's node is scoped out (404)"

      # Alice's node is untouched.
      get "/v1/tree", params: { after_id: 0 }, headers: auth(alice)
      assert_includes JSON.parse(response.body)["nodes"].map { |n| n["node_id"] }, alice_node
    end

    test "requests without a valid token are rejected" do
      get "/v1/tree", params: { after_id: 0 }, headers: { "Authorization" => "Bearer not-a-real-token" }
      assert_response :unauthorized
    end
  end
end
