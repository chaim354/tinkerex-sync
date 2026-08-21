require "test_helper"

class Sync::Sharing::LinksTest < ActiveSupport::TestCase
  setup do
    # No confirmed_at:/omniauth_signup: -- see test/models/share_link_test.rb's setup for why.
    @owner = User.create!(email: "o@example.com")
    # A file node with one immutable version + a 2-chunk manifest, owned by @owner.
    @node_id = SecureRandom.uuid
    @version_id = SecureRandom.uuid
    @manifest_id = SecureRandom.hex(16)
    @owner.nodes.create!(node_id: @node_id, name: "part.stl", kind: "file",
                         current_version_id: @version_id)
    @owner.versions.create!(version_id: @version_id, node_id: @node_id,
                            manifest_id: @manifest_id, size: 150)
    [ [ "a" * 64, 0, 100 ], [ "b" * 64, 100, 50 ] ].each_with_index do |(h, off, len), seq|
      Sync::ManifestChunk.create!(user_id: @owner.id, manifest_id: @manifest_id, chunk_hash: h,
                            seq:, offset: off, length: len)
      @owner.chunks.create!(chunk_hash: h, size: len, refcount: 1)
    end
  end

  test "create! returns a link carrying the raw token once, pointing at the version" do
    link = Sync::Sharing::Links.create_for_version!(user: @owner, node_id: @node_id,
                                                    version_id: @version_id)
    assert link.raw_token.present?
    assert_equal @version_id, link.version_id
    assert_equal @manifest_id, link.manifest_id
    # Only the digest is stored, never the raw token.
    assert_equal Sync::ShareLink.digest(link.raw_token), link.token_digest
  end

  test "redeem a live link returns a read capability with the version + manifest hashes" do
    raw = Sync::Sharing::Links.create_for_version!(user: @owner, node_id: @node_id,
                                                   version_id: @version_id).raw_token
    cap = Sync::Sharing::Links.redeem(raw)
    assert cap
    assert_equal @owner.id, cap.owner_id
    assert_equal @version_id, cap.version_id
    assert_equal @manifest_id, cap.manifest_id
    assert_equal Set["a" * 64, "b" * 64], cap.chunk_hashes
  end

  test "redeem of an unknown token returns nil" do
    assert_nil Sync::Sharing::Links.redeem("does-not-exist")
  end

  test "redeem of an expired link returns nil" do
    link = Sync::Sharing::Links.create_for_version!(user: @owner, node_id: @node_id,
                                                    version_id: @version_id, expires_at: 1.hour.ago)
    assert_nil Sync::Sharing::Links.redeem(link.raw_token)
  end

  test "redeem of a revoked link returns nil" do
    link = Sync::Sharing::Links.create_for_version!(user: @owner, node_id: @node_id,
                                                    version_id: @version_id)
    Sync::Sharing::Links.revoke!(link)
    assert_nil Sync::Sharing::Links.redeem(link.raw_token)
  end

  test "capability presign_urls only mints GETs for the version's own chunks" do
    Sync::Storage::ChunkStore.reset!
    raw = Sync::Sharing::Links.create_for_version!(user: @owner, node_id: @node_id,
                                                   version_id: @version_id).raw_token
    cap = Sync::Sharing::Links.redeem(raw)
    urls = cap.presign_urls
    assert_equal Set["a" * 64, "b" * 64], urls.keys.to_set
    # An unrelated chunk the owner happens to own is NOT mintable through this link.
    @owner.chunks.create!(chunk_hash: "c" * 64, size: 10, refcount: 1)
    cap2 = Sync::Sharing::Links.redeem(raw)
    refute_includes cap2.presign_urls.keys, "c" * 64
  end
end
