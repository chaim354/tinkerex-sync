require "test_helper"

module V1
  # Tenant = user. The whole security model is ordinary `user_id` scoping, so it must
  # actually hold at the API edge: one user's device token can never see or mutate
  # another user's tree, changelog, or nodes.
  class TenantIsolationTest < ActionDispatch::IntegrationTest
    # Isolation AT THE SYNC SURFACE (tree, changelog, nodes), which Phase 4 Task 7 gates to chunk
    # mode. On the HOST that gate is real: Sync::V1::CapabilityGate asks
    # Sync.capability_available?, which config/initializers/sync_capabilities.rb wires to
    # FileLayer.current.capabilities -- so a v1 sync test there had to `pin_file_layer_backend
    # ("chunk")` or risk 501ing under whatever LIBRARY_BACKEND happened to be ambient (bin/ci's
    # share/s3 legs run the WHOLE suite under a different one).
    #
    # `pin_file_layer_backend` DROPPED WHEN THIS TEST MOVED HERE -- it pinned
    # ENV["LIBRARY_BACKEND"] and called ::FileLayer.reset!, both host-only concepts (FileLayer is
    # HOST_CONSTANTS-guarded; this dummy has no equivalent). Nothing is weakened by dropping it:
    # in a bare mount Sync.capability_check stays at its DEFAULT_CAPABILITY_CHECK ("available,
    # always" -- lib/tinkerex_sync/sync_module.rb), because no host initializer overrides it, so
    # every capability these endpoints ask about is unconditionally true and there is nothing to
    # pin it AGAINST. This is the general shape for every "pin_file_layer_backend dropped" comment
    # in this suite; the other moved v1 integration tests point back here rather than repeating it.
    setup do
      Sync::Storage::ChunkStore.reset!
    end

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
      upload_chunks(JSON.parse(response.body))
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :success
      node_id
    end

    # PUT each presigned chunk URL so finalize's verify sees the bytes (memory store → /dev/blobs).
    def upload_chunks(began)
      (began["put_urls"] || {}).each_value do |url|
        put url, params: "x", headers: { "CONTENT_TYPE" => "application/octet-stream" }
      end
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
      upload_chunks(JSON.parse(response.body))
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
