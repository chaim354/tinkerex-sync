require "test_helper"

module V1
  # Read-only share links: an authenticated owner mints a link to one immutable version;
  # an ANONYMOUS client (no device token) redeems it to view metadata + presign GETs.
  class ShareLinksTest < ActionDispatch::IntegrationTest
    setup do
      # A share link is VERSION-scoped by construction (Sharing::Links.create_for_version!), so
      # minting one is a chunk-mode act and Phase 4 Task 7 gates the owner side on `versioned`.
      # Note "share link" here has nothing to do with FileLayer::Share -- see the controller.
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @token = bootstrap_account(email: "owner@example.com")["device_token"]
      @owner = User.find_by!(email: "owner@example.com")
      @node_id = SecureRandom.uuid
      @version_id = SecureRandom.uuid
      @manifest_id = SecureRandom.hex(16)
      @owner.nodes.create!(node_id: @node_id, name: "part.stl", kind: "file",
                           current_version_id: @version_id)
      @owner.versions.create!(version_id: @version_id, node_id: @node_id,
                              manifest_id: @manifest_id, size: 150)
      [ [ "a" * 64, 0, 100 ], [ "b" * 64, 100, 50 ] ].each_with_index do |(h, off, len), seq|
        Sync::ManifestChunk.create!(user_id: @owner.id, manifest_id: @manifest_id,
                              chunk_hash: h, seq:, offset: off, length: len)
        @owner.chunks.create!(chunk_hash: h, size: len, refcount: 1)
      end
    end

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    test "owner creates a share link, anonymous client views + presigns the version's chunks" do
      post "/v1/share_links",
           params: { node_id: @node_id, version_id: @version_id },
           as: :json, headers: auth(@token)
      assert_response :created
      body = JSON.parse(response.body)
      raw = body["token"]
      assert raw.present?, "should return the raw token once"

      # Anonymous: view metadata (NO device token).
      get "/v1/share/#{raw}"
      assert_response :success
      view = JSON.parse(response.body)
      assert_equal "part.stl", view["name"]
      assert_equal @version_id, view["version_id"]
      assert_equal 2, view["manifest"].size

      # Anonymous: presign the version's chunks.
      post "/v1/share/#{raw}/download"
      assert_response :success
      urls = JSON.parse(response.body)["urls"]
      assert_equal Set["a" * 64, "b" * 64], urls.keys.to_set
    end

    test "creating a link requires owning the version" do
      other = bootstrap_account(email: "stranger@example.com")["device_token"]
      post "/v1/share_links",
           params: { node_id: @node_id, version_id: @version_id },
           as: :json, headers: auth(other)
      assert_response :not_found
    end

    test "an unknown token is 404 on view and download" do
      get "/v1/share/nope"
      assert_response :not_found
      post "/v1/share/nope/download"
      assert_response :not_found
    end

    test "a revoked link is dead for anonymous view + download" do
      post "/v1/share_links",
           params: { node_id: @node_id, version_id: @version_id },
           as: :json, headers: auth(@token)
      raw = JSON.parse(response.body)["token"]
      link_id = JSON.parse(response.body)["id"]

      delete "/v1/share_links/#{link_id}", headers: auth(@token)
      assert_response :no_content

      get "/v1/share/#{raw}"
      assert_response :not_found
      post "/v1/share/#{raw}/download"
      assert_response :not_found
    end

    test "an owner cannot revoke another owner's link" do
      post "/v1/share_links",
           params: { node_id: @node_id, version_id: @version_id },
           as: :json, headers: auth(@token)
      link_id = JSON.parse(response.body)["id"]
      other = bootstrap_account(email: "stranger@example.com")["device_token"]
      delete "/v1/share_links/#{link_id}", headers: auth(other)
      assert_response :not_found
    end
  end
end
