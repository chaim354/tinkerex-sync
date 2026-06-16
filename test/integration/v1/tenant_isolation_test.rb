require "test_helper"

module V1
  # Tenant = user. The whole security model is ordinary `user_id` scoping, so it must
  # actually hold at the API edge: one user's device token can never see or mutate
  # another user's tree, changelog, or nodes.
  class TenantIsolationTest < ActionDispatch::IntegrationTest
    setup { Storage::ChunkStore.reset! }

    def register(email:)
      bootstrap_token(email: email, device_name: "d")
    end

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    def commit_file(token, name:, node_id: SecureRandom.uuid)
      cid = SecureRandom.uuid
      chunks = [ { hash: SecureRandom.hex(32), offset: 0, length: 5 } ]
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

    test "a user cannot move, restore, or read versions of another user's node" do
      alice = register(email: "alice3@example.com")
      bob = register(email: "bob3@example.com")
      alice_node = commit_file(alice, name: "secret.stl")

      post "/v1/nodes/#{alice_node}/move", params: { new_name: "stolen.stl" }, as: :json, headers: auth(bob)
      assert_response :not_found, "Bob can't move Alice's node"

      get "/v1/nodes/#{alice_node}/versions", headers: auth(bob)
      assert_response :not_found, "Bob can't list Alice's versions"

      post "/v1/nodes/#{alice_node}/restore", params: { version_id: SecureRandom.uuid }, as: :json, headers: auth(bob)
      assert_response :not_found, "Bob can't restore Alice's node"
    end

    test "chunk-download only mints URLs for chunks the requester owns" do
      alice = register(email: "alice4@example.com")
      bob = register(email: "bob4@example.com")
      # Alice commits a file; capture one of her chunk hashes.
      cid = SecureRandom.uuid
      ahash = SecureRandom.hex(32)
      post "/v1/commit",
           params: { commit_id: cid, node_id: SecureRandom.uuid, name: "a.bin", size: 5,
                     manifest: [ { hash: ahash, offset: 0, length: 5 } ] },
           as: :json, headers: auth(alice)
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(alice)

      # Bob asks for Alice's hash → no URL minted (he doesn't own that chunk).
      post "/v1/chunks/download", params: { hashes: [ ahash ] }, as: :json, headers: auth(bob)
      assert_response :success
      assert_empty JSON.parse(response.body)["urls"], "Bob gets no URL for a chunk he doesn't own"

      # Alice asks for her own hash → gets a URL, scoped to a per-user chunks/<id>/ prefix.
      post "/v1/chunks/download", params: { hashes: [ ahash ] }, as: :json, headers: auth(alice)
      url = JSON.parse(response.body)["urls"][ahash]
      assert url.present?, "Alice gets a URL for her own chunk"
      assert_match %r{chunks/\d+/#{ahash}}, url, "URL is scoped to the user's chunk prefix"
    end

    test "search never returns another user's nodes (same name)" do
      alice = register(email: "alice5@example.com")
      bob = register(email: "bob5@example.com")
      # Both have an identically-named file; search must stay scoped to the caller.
      alice_node = commit_file(alice, name: "secret-design.stl")
      bob_node = commit_file(bob, name: "secret-design.stl")

      get "/v1/search", params: { q: "secret-design" }, headers: auth(bob)
      assert_response :success
      ids = JSON.parse(response.body)["results"].map { |r| r["node_id"] }
      assert_includes ids, bob_node, "Bob finds his own node"
      assert_not_includes ids, alice_node, "Bob must NOT see Alice's identically-named node"
      assert_equal 1, ids.size
    end

    test "search requires a valid token" do
      get "/v1/search", params: { q: "x" }, headers: { "Authorization" => "Bearer nope" }
      assert_response :unauthorized
    end

    test "requests without a valid token are rejected" do
      get "/v1/tree", params: { after_id: 0 }, headers: { "Authorization" => "Bearer not-a-real-token" }
      assert_response :unauthorized
    end
  end
end
