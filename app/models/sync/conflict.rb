# An unresolved divergence on a file: two versions exist whose lineage we can't linearize
# (a device committed an edit based on a version that was no longer current — typically
# after editing offline and reconnecting). Rather than silently last-writer-wins and lose
# an edit, we record both sides and ask the user which is current (or to keep both).
class Sync::Conflict < ::ApplicationRecord
  belongs_to :user, class_name: "::User"

  scope :unresolved, -> { where(resolved_at: nil) }

  def resolved? = resolved_at.present?
end
