class ManifestChunk < ApplicationRecord
  belongs_to :user

  # A manifest is identified by manifest_id (SHA-256 of the ordered chunk-hash list,
  # matching the client). Existence of any row for (user, manifest_id) means the
  # manifest is stored.
  def self.manifest_exists?(user_id:, manifest_id:)
    where(user_id:, manifest_id:).exists?
  end
end
