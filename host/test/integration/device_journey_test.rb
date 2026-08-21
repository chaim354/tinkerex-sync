# frozen_string_literal: true

require "test_helper"

# THE JOURNEY A REAL CLIENT MAKES, END TO END, AGAINST THE STANDALONE HOST.
#
# Everything before this proved pieces: the gem's boot_test proves the engine mounts, the maker
# app's suites prove FileLayer::ChunkRemote speaks the protocol. Nothing proved the two halves meet
# — that a token minted by an operator on THIS host authenticates against the engine's endpoints and
# carries a file all the way through. That is the only claim Stage 4 rests on that nothing else
# makes.
class DeviceJourneyTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "operator@example.com")
    @device = Device.register!(user: @user, name: "maker-app")
    @token = @device.plaintext_token
    @auth = { "Authorization" => "Bearer #{@token}" }
  end

  test "an operator-minted token authenticates against the engine's endpoints" do
    get "/v1/devices/whoami", headers: @auth
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @user.id, body["user_id"]
    assert_equal 0, body["head_seq"], "a fresh library has issued no seqs"
  end

  test "an unknown token is refused, so the engine is not open" do
    get "/v1/tree", headers: { "Authorization" => "Bearer not-a-real-token" }
    assert_response :unauthorized
  end

  test "no token at all is refused" do
    get "/v1/tree"
    assert_response :unauthorized
  end

  test "a device enrols a sibling without any password existing anywhere" do
    # The fleet grows from the first operator-minted token. This is why the host ships no password
    # login: there is nothing a second device needs that the first cannot give it.
    post "/v1/devices", params: { name: "laptop" }, headers: @auth
    assert_response :created
    sibling = JSON.parse(response.body)
    assert sibling["device_token"].present?

    get "/v1/devices/whoami", headers: { "Authorization" => "Bearer #{sibling['device_token']}" }
    assert_response :success
    assert_equal @user.id, JSON.parse(response.body)["user_id"],
                 "an enrolled sibling must land on the SAME library, not a new one"
  end

  test "the full file journey: commit, changelog, hydrate, bytes back" do
    bytes = "standalone host round trip"
    hash = Digest::SHA256.hexdigest(bytes)
    Sync::Storage::ChunkStore.current.put!(@user.id, hash, bytes)

    node_id = SecureRandom.uuid
    commit_id = SecureRandom.uuid
    post "/v1/commit", headers: @auth, params: {
      commit_id:, node_id:, name: "journey.stl", size: bytes.bytesize,
      mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
      manifest: [ { hash:, offset: 0, length: bytes.bytesize } ]
    }
    assert_response :success

    post "/v1/commit/#{commit_id}/finalize", headers: @auth
    assert_response :success
    version_id = JSON.parse(response.body)["version_id"]
    assert version_id.present?

    # The changelog is what a maker app in chunk_remote mode pulls, so its shape matters as much as
    # the commit's success.
    get "/v1/changes", params: { since: 0 }, headers: @auth
    assert_response :success
    changes = JSON.parse(response.body)
    entry = changes["changes"].find { |c| c["node_id"] == node_id }
    assert entry, "the commit produced no changelog entry for a client to apply"
    assert_equal "journey.stl", entry.dig("node", "name")
    assert_equal bytes.bytesize, entry.dig("version", "size"),
                 "size rides on the version -- FileLayer::ChunkRemote records it on the node from here"
    assert_equal [ hash ], entry["manifest"].map { |m| m["hash"] },
                 "the manifest must ride along, or a client can never name the chunks to hydrate"

    # And hydrate: the server presigns, it does not proxy (§15).
    post "/v1/chunks/download", params: { hashes: [ hash ] }, headers: @auth
    assert_response :success
    url = JSON.parse(response.body).dig("urls", hash)
    assert url.present?, "the server would not presign a chunk it just accepted"

    get URI.parse(url).path
    assert_response :success
    assert_equal bytes, response.body.b
  end
end
