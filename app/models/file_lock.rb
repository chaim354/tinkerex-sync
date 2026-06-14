# A best-effort, advisory cross-device edit lock. Held by one device with a TTL, so a
# disconnected/crashed holder's lock frees itself. It's *advisory*: it never blocks a
# commit (the offline path skips it entirely and conflict detection is the safety net) —
# it exists so connected clients can avoid colliding before they diverge.
class FileLock < ApplicationRecord
  belongs_to :user

  scope :active, -> { where("expires_at > ?", Time.current) }
end
