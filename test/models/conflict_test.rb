require "test_helper"

class ConflictTest < ActiveSupport::TestCase
  # Correction, 2026-08-20 (Stage 3a Task 7, docs/superpowers/plans/2026-08-20-stage-3a-decouple-
  # the-engine.md): `conflicts.user_id` had no database-level foreign key -- `t.integer :user_id,
  # null: false` where every sibling engine table uses `t.references :user, foreign_key: true` --
  # and nothing recorded why. Added in
  # db/migrate/20260820181025_add_user_foreign_key_to_conflicts_and_file_locks.rb.
  #
  # `validate: false` IS THE POINT, NOT A SHORTCUT. `belongs_to :user` already raises on a
  # missing user through Rails' OWN presence validation -- an application-level SELECT that would
  # pass this test whether or not the migration's constraint exists, which is this repo's
  # recorded failure shape (CLAUDE.md §15): a guard that cannot fail for the reason it exists.
  # Skipping validation is what forces the INSERT to reach SQLite and prove the CONSTRAINT, not
  # the model's own belongs_to check, is what refuses it.
  test "the database itself refuses a user_id that does not exist, not just the belongs_to validation" do
    bad_user_id = (User.maximum(:id) || 0) + 999_999
    conflict = Conflict.new(user_id: bad_user_id, node_id: "n1",
                             current_version_id: "v-current", incoming_version_id: "v-incoming")

    assert_raises(ActiveRecord::InvalidForeignKey) { conflict.save!(validate: false) }
  end
end
