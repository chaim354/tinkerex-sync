class Version < ApplicationRecord
  belongs_to :user

  validates :version_id, presence: true, uniqueness: { scope: :user_id }
  validates :node_id, presence: true
  validates :manifest_id, presence: true

  # The ordered chunk list for this version's manifest.
  def manifest_chunks
    ManifestChunk.where(user_id:, manifest_id:).order(:seq)
  end
end
