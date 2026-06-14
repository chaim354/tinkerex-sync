class ChangelogEntry < ApplicationRecord
  belongs_to :user

  # `conflict` = a divergent edit recorded (not applied as current) — see Sync::Commit.
  OPS = %w[put mkdir delete move conflict].freeze

  validates :seq, presence: true, uniqueness: { scope: :user_id }
  validates :node_id, presence: true
  validates :op, inclusion: { in: OPS }

  scope :since, ->(seq) { where("seq > ?", seq).order(:seq) }
end
