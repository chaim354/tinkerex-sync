# THE SMALLEST User THAT SATISFIES WHAT THE ENGINE ACTUALLY USES -- not a copy of the host's
# (which additionally carries the full Devise stack: database_authenticatable, registerable,
# confirmable, lockable, omniauth, and a dozen columns none of engines/tinkerex-sync/app or lib
# ever reads). Read the engine's own code, not the host's model, to find the real surface:
#
#   - `belongs_to :user, class_name: "::User"` on all eight Sync:: models -- needs a `users`
#     table this dummy's own migration provides, nothing more.
#   - `User.find_each` (app/services/sync/{retention_job,pending_commit_reaper,chunk_reaper}.rb),
#     `User.find(cap.owner_id)` (share_controller.rb) -- stock ActiveRecord finders, free.
#   - `user.next_seq!` / `user.head_seq` -- the changelog sequence allocator (CLAUDE.md §14e's
#     FOR UPDATE row-lock precedent). This is the ONE piece of real behaviour the engine demands
#     of User beyond bare AR, so it is copied verbatim below, comments and all.
#   - The seven `has_many :versions, class_name: "Sync::Version", dependent: :destroy` etc. --
#     needed by every test that reaches a user's rows via association (`user.nodes`,
#     `user.chunks`, `user.versions`...) rather than a bare `Sync::Version.where(...)`.
#
# NOT PORTED: Devise, `omniauth_signup`, `confirmed_at`/confirmation columns, `password_set?`,
# `from_omniauth`. Nothing under engines/tinkerex-sync ever asks a User whether it is confirmed
# or has a password -- Device.authenticate is the only credential the sync API accepts, and it
# never consults the user record at all beyond `device.user`. A handful of moved tests originally
# passed `confirmed_at:`/`omniauth_signup:` to User.create! (copied from the host's
# bootstrap_account test helper); those two kwargs were dropped when the tests moved, because
# nothing they assert reads either value -- see this dummy's test_helper.rb for the trimmed
# bootstrap_account/bootstrap_token.
class User < ApplicationRecord
  has_many :nodes, dependent: :destroy
  has_many :devices, dependent: :destroy
  has_many :versions, class_name: "Sync::Version", dependent: :destroy
  has_many :chunks, class_name: "Sync::Chunk", dependent: :destroy
  has_many :changelog_entries, class_name: "Sync::ChangelogEntry", dependent: :destroy
  has_many :pending_commits, class_name: "Sync::PendingCommit", dependent: :destroy
  has_many :conflicts, class_name: "Sync::Conflict", dependent: :destroy
  has_many :file_locks, class_name: "Sync::FileLock", dependent: :destroy
  has_many :share_links, class_name: "Sync::ShareLink", dependent: :destroy

  validates :email, presence: true, uniqueness: true

  # Verbatim from app/models/user.rb (the host), including its own comment -- this is the one
  # piece of real User BEHAVIOUR the engine depends on, not merely a column.
  #
  # Assign the next per-user changelog sequence. MUST be called inside a transaction, and
  # MUST be the FIRST write in it (before any node/version/changelog insert): locks the user
  # row so concurrent commits from multiple devices get distinct, ordered seqs. Portable --
  # `SELECT … FOR UPDATE` on Postgres; a harmless reload on SQLite (which serializes writes
  # globally anyway).
  def next_seq!
    lock!
    new_seq = head_seq + 1
    update_column(:head_seq, new_seq)
    new_seq
  end
end
