require "test_helper"

class ShareLinkTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "owner@example.com", confirmed_at: Time.current, omniauth_signup: true)
  end

  test "live? is true with no expiry and no revocation" do
    link = ShareLink.create!(user: @user, node_id: "n1", version_id: "v1",
                             manifest_id: "m1", token_digest: ShareLink.digest("raw"))
    assert link.live?
  end

  test "live? is false when expired" do
    link = ShareLink.create!(user: @user, node_id: "n1", version_id: "v1",
                             manifest_id: "m1", token_digest: ShareLink.digest("raw"),
                             expires_at: 1.hour.ago)
    refute link.live?
  end

  test "live? is false when revoked" do
    link = ShareLink.create!(user: @user, node_id: "n1", version_id: "v1",
                             manifest_id: "m1", token_digest: ShareLink.digest("raw"),
                             revoked_at: Time.current)
    refute link.live?
  end

  test "digest is stable SHA256 of the raw token" do
    assert_equal Digest::SHA256.hexdigest("raw"), ShareLink.digest("raw")
  end
end
