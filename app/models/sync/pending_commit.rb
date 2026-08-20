class Sync::PendingCommit < ::ApplicationRecord
  belongs_to :user, class_name: "::User"

  validates :commit_id, presence: true, uniqueness: { scope: :user_id }
  validates :node_id, :name, :manifest_id, presence: true

  # The manifest chunk list ([{ "hash", "offset", "length" }, ...]) parsed from JSON.
  def manifest
    JSON.parse(manifest_json)
  end
end
