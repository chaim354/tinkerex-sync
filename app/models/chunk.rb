class Chunk < ApplicationRecord
  belongs_to :user

  validates :chunk_hash, presence: true, uniqueness: { scope: :user_id }
end
