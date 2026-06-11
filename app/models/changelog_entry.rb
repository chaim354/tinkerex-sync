class ChangelogEntry < ApplicationRecord
  belongs_to :user

  OPS = %w[put mkdir delete move].freeze

  validates :seq, presence: true, uniqueness: { scope: :user_id }
  validates :node_id, presence: true
  validates :op, inclusion: { in: OPS }

  scope :since, ->(seq) { where("seq > ?", seq).order(:seq) }
end
