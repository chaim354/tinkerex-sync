# A read-only share link: a capability token granting anonymous GET access to ONE
# immutable version of ONE file owned by `user`. This is the deliberately shallow slice
# of the sharing arc (docs/plan-sharing.md) — it adds cross-user *read* access WITHOUT
# touching the per-user chunk keyspace or tenancy model: a redeemed link mints presigned
# GETs against the OWNER's own keyspace (chunks/<user_id>/<hash>), scoped to exactly the
# chunk hashes named by the target version's manifest. Full read/write sharing (Spaces,
# per-Space keyspace) remains planned, not built.
class Sync::ShareLink < ::ApplicationRecord
  belongs_to :user, class_name: "::User"

  validates :node_id, :version_id, :manifest_id, presence: true
  validates :token_digest, presence: true, uniqueness: true

  # Live = not revoked and not past its expiry. Checked on every redeem AND on every
  # presign mint, so revocation/expiry cut access on the next request (already-minted
  # short-TTL URLs live out their TTL — the same bound as device-token presigns).
  def live?
    revoked_at.nil? && (expires_at.nil? || expires_at.future?)
  end

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end
end
