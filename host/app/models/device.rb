# Byte-identical to the host's app/models/device.rb -- it was ALREADY the smallest Device that
# satisfies the engine (no Devise, no bcrypt: SecureRandom + SHA256 only), so there was nothing
# to trim. `Device.authenticate` is the whole v1 credential
# (engines/tinkerex-sync/app/controllers/concerns/sync/v1/authentication.rb); `touch_seen!` and
# `.user` are called on the authenticated instance from the same concern.
class Device < ApplicationRecord
  belongs_to :user

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  # The plaintext token is returned exactly once, at registration; only its digest is stored.
  attr_reader :plaintext_token

  def self.register!(user:, name: "device")
    token = SecureRandom.urlsafe_base64(32)
    device = create!(user:, name:, token_digest: digest(token))
    device.instance_variable_set(:@plaintext_token, token)
    device
  end

  def self.authenticate(token)
    return nil if token.blank?
    find_by(token_digest: digest(token))
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  def touch_seen!
    update_column(:last_seen_at, Time.current)
  end
end
