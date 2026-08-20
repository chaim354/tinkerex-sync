require "test_helper"

module V1
  # Correctness/security guards on the v1 node + commit + chunk endpoints:
  #   - move/mkdir cycle guard (a self/descendant re-parent would wedge search forever)
  #   - directory delete cascades the tombstone to the whole subtree
  #   - finalize verifies uploads actually landed
  #   - kind-change guard (409, not a silent orphan)
  #   - malformed / over-cap chunk hashes rejected
  #   - benign-but-invalid input renders 4xx, never 500
  class NodeGuardsTest < ActionDispatch::IntegrationTest
    # Guards on the sync engine's own mutation surface, which is chunk-mode only (spec §3.3) as of
    # Phase 4 Task 7's gate. Pinned, not rewritten: every assertion below is still exactly right
    # about the deployment it was always describing.
    setup do
      pin_file_layer_backend("chunk")
      Sync::Storage::ChunkStore.reset!
    end

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    def mkdir(token, node_id:, name:, parent: nil)
      post "/v1/nodes", params: { node_id:, name:, parent_node_id: parent }, as: :json, headers: auth(token)
    end

    # begin -> PUT bytes -> finalize a one-chunk file. Returns node_id.
    def commit_file(token, name:, node_id: SecureRandom.uuid, parent: nil, hash: SecureRandom.hex(32))
      cid = SecureRandom.uuid
      post "/v1/commit",
           params: { commit_id: cid, node_id:, parent_node_id: parent, name:, base_version_id: nil,
                     size: 5, manifest: [ { hash:, offset: 0, length: 5 } ] },
           as: :json, headers: auth(token)
      assert_response :success
      (JSON.parse(response.body)["put_urls"] || {}).each_value do |url|
        put url, params: "x", headers: { "CONTENT_TYPE" => "application/octet-stream" }
      end
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :success
      node_id
    end

    # ---- Fix 2: move cycle guard ---------------------------------------------

    test "moving a node into itself is rejected (422) and does not corrupt the tree" do
      token = bootstrap_token(email: "cyc1@example.com")
      dir = SecureRandom.uuid
      mkdir(token, node_id: dir, name: "d")
      assert_response :created

      post "/v1/nodes/#{dir}/move", params: { new_parent_node_id: dir }, as: :json, headers: auth(token)
      assert_response :unprocessable_entity

      # Search still returns promptly (no runaway recursion) and the dir is intact.
      get "/v1/search", params: { q: "d" }, headers: auth(token)
      assert_response :success
    end

    test "moving a node into its own descendant is rejected (422)" do
      token = bootstrap_token(email: "cyc2@example.com")
      parent = SecureRandom.uuid
      child = SecureRandom.uuid
      mkdir(token, node_id: parent, name: "parent")
      mkdir(token, node_id: child, name: "child", parent: parent)
      assert_response :created

      # Try to move `parent` under `child` (its own descendant) → cycle.
      post "/v1/nodes/#{parent}/move", params: { new_parent_node_id: child }, as: :json, headers: auth(token)
      assert_response :unprocessable_entity

      get "/v1/search", params: { q: "parent" }, headers: auth(token)
      assert_response :success
      assert(JSON.parse(response.body)["results"].any? { |r| r["node_id"] == parent })
    end

    test "a legitimate move still works" do
      token = bootstrap_token(email: "mv-ok@example.com")
      a = SecureRandom.uuid
      b = SecureRandom.uuid
      mkdir(token, node_id: a, name: "a")
      mkdir(token, node_id: b, name: "b")
      post "/v1/nodes/#{b}/move", params: { new_parent_node_id: a }, as: :json, headers: auth(token)
      assert_response :success
    end

    # ---- Fix 4: directory delete cascades to the subtree ---------------------

    test "deleting a folder tombstones the whole subtree in tree AND changelog" do
      token = bootstrap_token(email: "casc@example.com")
      dir = SecureRandom.uuid
      mkdir(token, node_id: dir, name: "Projects")
      assert_response :created
      child_file = commit_file(token, name: "part.stl", parent: dir)
      sub = SecureRandom.uuid
      mkdir(token, node_id: sub, name: "sub", parent: dir)
      grandchild = commit_file(token, name: "deep.stl", parent: sub)

      delete "/v1/nodes/#{dir}", headers: auth(token)
      assert_response :success

      # Snapshot: none of the subtree survives as `present`.
      get "/v1/tree", headers: auth(token)
      tree_ids = JSON.parse(response.body)["nodes"].map { |n| n["node_id"] }
      [ dir, child_file, sub, grandchild ].each do |id|
        assert_not_includes tree_ids, id, "#{id} must be gone from the snapshot"
      end

      # Changelog: a delete entry rode for every affected node.
      get "/v1/changes", params: { since: 0 }, headers: auth(token)
      deleted_in_log = JSON.parse(response.body)["changes"].select { |c| c["op"] == "delete" }.map { |c| c["node_id"] }
      [ dir, child_file, sub, grandchild ].each do |id|
        assert_includes deleted_in_log, id, "#{id} must carry a delete in the changelog"
      end
    end

    # ---- Fix 6: finalize verifies the upload landed --------------------------

    test "finalizing a commit whose chunks were never uploaded is rejected" do
      # verify-on-finalize is opt-in (config/initializers/finalize_verification.rb); enable it
      # for this test, which asserts the rejection behavior it guards.
      prior = Rails.configuration.x.verify_finalize
      Rails.configuration.x.verify_finalize = true
      token = bootstrap_token(email: "verify@example.com")
      cid = SecureRandom.uuid
      post "/v1/commit",
           params: { commit_id: cid, node_id: SecureRandom.uuid, name: "phantom.bin", base_version_id: nil,
                     size: 5, manifest: [ { hash: SecureRandom.hex(32), offset: 0, length: 5 } ] },
           as: :json, headers: auth(token)
      assert_response :success
      # NOTE: no PUT of the bytes.
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :unprocessable_entity
      assert_equal "chunks_missing", JSON.parse(response.body)["error"]
    ensure
      Rails.configuration.x.verify_finalize = prior
    end

    # ---- Fix 8: kind-change guard --------------------------------------------

    test "mkdir on an existing file node is rejected (409)" do
      token = bootstrap_token(email: "kind1@example.com")
      nid = commit_file(token, name: "afile.bin")
      post "/v1/nodes", params: { node_id: nid, name: "afile.bin" }, as: :json, headers: auth(token)
      assert_response :conflict
    end

    test "committing a file onto an existing dir node is rejected (409)" do
      token = bootstrap_token(email: "kind2@example.com")
      dir = SecureRandom.uuid
      mkdir(token, node_id: dir, name: "d")
      cid = SecureRandom.uuid
      post "/v1/commit",
           params: { commit_id: cid, node_id: dir, name: "d", base_version_id: nil, size: 5,
                     manifest: [ { hash: SecureRandom.hex(32), offset: 0, length: 5 } ] },
           as: :json, headers: auth(token)
      assert_response :success
      # Upload the bytes so finalize's verify passes and we actually reach the kind check.
      (JSON.parse(response.body)["put_urls"] || {}).each_value do |url|
        put url, params: "x", headers: { "CONTENT_TYPE" => "application/octet-stream" }
      end
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :conflict
    end

    # ---- Fix 1/10: chunk hash validation + caps on the API edge ---------------

    test "commit with a traversal chunk hash is rejected (422)" do
      token = bootstrap_token(email: "hash1@example.com")
      post "/v1/commit",
           params: { commit_id: SecureRandom.uuid, node_id: SecureRandom.uuid, name: "e.bin",
                     base_version_id: nil, size: 5,
                     manifest: [ { hash: "../7/deadbeef", offset: 0, length: 5 } ] },
           as: :json, headers: auth(token)
      assert_response :unprocessable_entity
    end

    test "chunks/download ignores malformed hashes and caps the batch" do
      token = bootstrap_token(email: "hash2@example.com")
      # A malformed hash never yields a URL.
      post "/v1/chunks/download", params: { hashes: [ "../etc/passwd" ] }, as: :json, headers: auth(token)
      assert_response :success
      assert_empty JSON.parse(response.body)["urls"]

      # Over the cap → 422.
      too_many = Array.new(V1::ChunksController::MAX_DOWNLOAD_HASHES + 1) { SecureRandom.hex(32) }
      post "/v1/chunks/download", params: { hashes: too_many }, as: :json, headers: auth(token)
      assert_response :unprocessable_entity
    end

    # ---- Fix 7d: benign-but-invalid conflict resolution renders 422, not 500 --

    test "resolve_conflict with a version not part of the conflict returns 422" do
      token = bootstrap_token(email: "keep-bad@example.com")
      # Manufacture a conflict: two commits on the same node with the same stale base.
      nid = SecureRandom.uuid
      first = commit_file(token, name: "c.bin", node_id: nid)
      # Base off a bogus version to force a divergence from a *different* device.
      other = bootstrap_account(email: "keep-bad@example.com", device_name: "dev2")
      cid = SecureRandom.uuid
      post "/v1/commit",
           params: { commit_id: cid, node_id: nid, name: "c.bin", base_version_id: SecureRandom.uuid,
                     size: 5, manifest: [ { hash: SecureRandom.hex(32), offset: 0, length: 5 } ] },
           as: :json, headers: auth(other["device_token"])
      assert_response :success
      (JSON.parse(response.body)["put_urls"] || {}).each_value do |url|
        put url, params: "x", headers: { "CONTENT_TYPE" => "application/octet-stream" }
      end
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(other["device_token"])

      # Now resolve with a version_id that is not part of the conflict → ArgumentError → 422.
      post "/v1/nodes/#{nid}/resolve_conflict",
           params: { keep_version_id: SecureRandom.uuid }, as: :json, headers: auth(token)
      assert_response :unprocessable_entity
    end
  end
end
