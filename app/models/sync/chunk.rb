class Sync::Chunk < ::ApplicationRecord
  belongs_to :user, class_name: "::User"

  validates :chunk_hash, presence: true, uniqueness: { scope: :user_id }
end
