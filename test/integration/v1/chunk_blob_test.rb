require "test_helper"

module V1
  # The `local` chunk backend's HTTP storage tier (V1::Chunks::BlobController): real presigned
  # PUT/GET of chunk BYTES, authorized by the URL's HMAC signature (no bearer token). This is the
  # self-hosted single-box data plane that lets two devices move bytes without an external object
  # store — exercised end-to-end by the two-device real-mount tests.
  class ChunkBlobTest < ActionDispatch::IntegrationTest
    setup do
      @dir = Dir.mktmpdir("chunk-blob-test")
      Storage::ChunkStore.reset!
      Storage::ChunkStore.current = Storage::LocalChunkStore.new(dir: @dir, public_url: "http://www.example.com")
    end
    teardown do
      Storage::ChunkStore.reset!
      FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
    end

    HASH = "abc123def4560000"

    def blob_path(user_id, hash, expires_in: 900)
      url = Storage::LocalChunkStore.new(dir: @dir).presign_put(user_id, hash, expires_in:)
      URI(url).request_uri # path + query, as the client would hit it
    end

    test "PUT then GET round-trips the exact bytes through the HTTP tier" do
      bytes = "\x00\x01\x02chunk-bytes\xff".b
      put blob_path(7, HASH), params: bytes, headers: { "Content-Type" => "application/octet-stream" }
      assert_response :ok

      get blob_path(7, HASH)
      assert_response :ok
      assert_equal bytes, response.body.b
    end

    test "GET of an absent chunk is 404 (with a valid signature)" do
      get blob_path(7, "feedface00001111")
      assert_response :not_found
    end

    test "a tampered signature is rejected (403)" do
      path = blob_path(7, HASH)
      tampered = path.sub(/sig=[0-9a-f]+/, "sig=#{'0' * 64}")
      get tampered
      assert_response :forbidden
    end

    test "an expired URL is rejected (403) even if well-formed" do
      # expires_in: -1 → exp already in the past, but the signature is otherwise valid.
      get blob_path(7, HASH, expires_in: -1)
      assert_response :forbidden
    end

    test "the blob endpoints 404 when the backend is not the local store" do
      Storage::ChunkStore.reset!
      Storage::ChunkStore.current = Storage::MemoryChunkStore.new
      # Sign with the same key so the sig check would pass; the backend guard must still 404.
      exp = (Time.now + 900).to_i
      sig = Storage::LocalChunkStore.sign(7, HASH, exp)
      get "/v1/chunks/blob/7/#{HASH}?exp=#{exp}&sig=#{sig}"
      assert_response :not_found
    end
  end
end
