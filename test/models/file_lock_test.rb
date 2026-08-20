require "test_helper"

class FileLockTest < ActiveSupport::TestCase
  # Correction, 2026-08-20 (Stage 3a Task 7) -- see ConflictTest for the full argument for why
  # `validate: false` is required rather than incidental; same migration
  # (db/migrate/20260820181025_add_user_foreign_key_to_conflicts_and_file_locks.rb), same shape.
  #
  # `device_id: 0` is deliberate, not a placeholder that happens to work: this task's scope is
  # only the missing `user_id` FK (Stage 3 boundary design §5). `file_locks.device_id` has no
  # foreign key either, undisturbed by this migration, so an arbitrary device id is exactly as
  # valid at the database level as a real one -- proving that stays true is not this test's job.
  test "the database itself refuses a user_id that does not exist, not just the belongs_to validation" do
    bad_user_id = (User.maximum(:id) || 0) + 999_999
    lock = Sync::FileLock.new(user_id: bad_user_id, node_id: "n1", device_id: 0,
                         expires_at: 1.hour.from_now)

    assert_raises(ActiveRecord::InvalidForeignKey) { lock.save!(validate: false) }
  end
end
