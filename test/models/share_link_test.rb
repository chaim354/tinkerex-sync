require "test_helper"

class ShareLinkTest < ActiveSupport::TestCase
  setup do
    # No confirmed_at:/omniauth_signup: -- Devise-only columns/attr this dummy's User does not
    # carry (test/dummy/app/models/user.rb), and Sync::ShareLink.live? (the whole subject here)
    # never asks a user whether it is confirmed.
    @user = User.create!(email: "owner@example.com")
  end

  test "live? is true with no expiry and no revocation" do
    link = Sync::ShareLink.create!(user: @user, node_id: "n1", version_id: "v1",
                             manifest_id: "m1", token_digest: Sync::ShareLink.digest("raw"))
    assert link.live?
  end

  test "live? is false when expired" do
    link = Sync::ShareLink.create!(user: @user, node_id: "n1", version_id: "v1",
                             manifest_id: "m1", token_digest: Sync::ShareLink.digest("raw"),
                             expires_at: 1.hour.ago)
    refute link.live?
  end

  test "live? is false when revoked" do
    link = Sync::ShareLink.create!(user: @user, node_id: "n1", version_id: "v1",
                             manifest_id: "m1", token_digest: Sync::ShareLink.digest("raw"),
                             revoked_at: Time.current)
    refute link.live?
  end

  test "digest is stable SHA256 of the raw token" do
    assert_equal Digest::SHA256.hexdigest("raw"), Sync::ShareLink.digest("raw")
  end
end
