class Sync::ChangelogEntry < ::ApplicationRecord
  belongs_to :user, class_name: "::User"

  # `conflict` = a divergent edit recorded (not applied as current) — see Sync::Commit.
  # `symlink` = a symlink node created/updated (metadata-only, target on the node).
  OPS = %w[put mkdir delete move conflict symlink].freeze

  validates :seq, presence: true, uniqueness: { scope: :user_id }
  validates :node_id, presence: true
  validates :op, inclusion: { in: OPS }

  scope :since, ->(seq) { where("seq > ?", seq).order(:seq) }
end
