require "test_helper"

module V1
  # Trash / undelete over the v1 API: list tombstoned nodes, restore one (which
  # un-tombstones + appends a changelog entry so other devices converge), and
  # cross-user isolation (you can't see or restore another user's trash).
  class TrashFlowTest < ActionDispatch::IntegrationTest
    setup { Storage::ChunkStore.reset! }

    def register(email:, name: "laptop")
      post "/v1/auth/register", params: { email:, device_name: name }, as: :json
      assert_response :created
      JSON.parse(response.body)["device_token"]
    end

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    def commit_file(token, name:, node_id: SecureRandom.uuid, hash: "1" * 64)
      cid = SecureRandom.uuid
      post "/v1/commit",
           params: { commit_id: cid, node_id:, parent_node_id: nil, name:, base_version_id: nil,
                     size: 5, manifest: [ { hash:, offset: 0, length: 5 } ] },
           as: :json, headers: auth(token)
      assert_response :success
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :success
      node_id
    end

    test "delete -> trash lists it -> restore brings it back" do
      token = register(email: "trash-api@example.com")
      node_id = commit_file(token, name: "part.stl")

      delete "/v1/nodes/#{node_id}", headers: auth(token)
      assert_response :success

      get "/v1/trash", headers: auth(token)
      assert_response :success
      items = JSON.parse(response.body)["items"]
      assert_equal 1, items.size
      assert_equal node_id, items.first["node_id"]
      assert_equal "part.stl", items.first["name"]
      assert_equal 5, items.first["size"]
      assert items.first["deleted_at"].present?

      post "/v1/trash/#{node_id}/restore", as: :json, headers: auth(token)
      assert_response :success
      assert JSON.parse(response.body)["seq"]

      # Back in the live tree; trash is now empty.
      get "/v1/tree", headers: auth(token)
      assert_response :success
      assert(JSON.parse(response.body)["nodes"].any? { |n| n["node_id"] == node_id })

      get "/v1/trash", headers: auth(token)
      assert_empty JSON.parse(response.body)["items"]
    end

    test "restore appends a changelog entry so other devices converge" do
      token = register(email: "trash-cl@example.com")
      node_id = commit_file(token, name: "f.bin")
      delete "/v1/nodes/#{node_id}", headers: auth(token)

      get "/v1/changes", params: { since: 0 }, headers: auth(token)
      cursor = JSON.parse(response.body)["changes"].last["seq"]

      post "/v1/trash/#{node_id}/restore", as: :json, headers: auth(token)
      assert_response :success

      get "/v1/changes", params: { since: cursor }, headers: auth(token)
      changes = JSON.parse(response.body)["changes"]
      assert_equal 1, changes.size
      assert_equal "put", changes.first["op"]
      assert_equal node_id, changes.first["node_id"]
    end

    test "restoring an orphaned node returns 409 unless to_root" do
      token = register(email: "trash-orphan@example.com")
      dir_id = SecureRandom.uuid
      post "/v1/nodes", params: { node_id: dir_id, name: "Projects" }, as: :json, headers: auth(token)
      assert_response :created
      child = commit_file(token, name: "child.stl")
      # Move child under the dir, then delete both.
      post "/v1/nodes/#{child}/move", params: { new_parent_node_id: dir_id }, as: :json, headers: auth(token)
      delete "/v1/nodes/#{child}", headers: auth(token)
      delete "/v1/nodes/#{dir_id}", headers: auth(token)

      post "/v1/trash/#{child}/restore", as: :json, headers: auth(token)
      assert_response :conflict
      assert_equal "parent_deleted", JSON.parse(response.body)["error"]

      post "/v1/trash/#{child}/restore", params: { to_root: true }, as: :json, headers: auth(token)
      assert_response :success
      assert_nil JSON.parse(response.body)["parent_node_id"]
    end

    test "isolation: a user cannot see or restore another user's trash" do
      alice = register(email: "alice-trash@example.com")
      alice_node = commit_file(alice, name: "secret.stl")
      delete "/v1/nodes/#{alice_node}", headers: auth(alice)

      bob = register(email: "bob-trash@example.com")

      # Bob's trash is empty — never alice's tombstone.
      get "/v1/trash", headers: auth(bob)
      assert_empty JSON.parse(response.body)["items"]

      # Bob can't restore alice's node.
      post "/v1/trash/#{alice_node}/restore", as: :json, headers: auth(bob)
      assert_response :not_found

      # And it's still deleted for alice.
      get "/v1/trash", headers: auth(alice)
      assert_equal 1, JSON.parse(response.body)["items"].size
    end
  end
end
