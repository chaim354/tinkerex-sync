require "test_helper"

# The scheduled storage-orphan reaper job iterates every user and deletes leaked chunk
# bytes (uploaded-but-never-finalized objects with no DB row). It DELEGATES to the tested
# Sync::ChunkReaper.reap_all! — it must not reimplement reaping.
class ChunkReaperJobTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 6, 1, 12, 0, 0)
    Sync::Storage::ChunkStore.reset!
    @store = Sync::Storage::ChunkStore.current
    # reap_all! enumerates the whole keyspace; wipe the persistent memory-store dir so
    # leftover objects from other tests don't inflate the count.
    FileUtils.rm_rf(@store.root)
    FileUtils.mkdir_p(@store.root)
  end

  def leak!(user, age: 2.days)
    h = SecureRandom.hex(32)
    @store.put!(user.id, h, "bytes")
    @store.set_mtime!(user.id, h, age.ago)
    h
  end

  test "reaps leaked objects across every user" do
    u1 = User.create!(email: "j1@example.com")
    u2 = User.create!(email: "j2@example.com")
    h1 = leak!(u1)
    h2 = leak!(u2)

    reaped = ChunkReaperJob.perform_now

    assert_equal 2, reaped
    assert_not @store.exists?(u1.id, h1)
    assert_not @store.exists?(u2.id, h2)
  end

  test "dry_run deletes nothing" do
    u1 = User.create!(email: "j3@example.com")
    h1 = leak!(u1)

    reaped = ChunkReaperJob.perform_now(dry_run: true)

    assert_equal 1, reaped
    assert @store.exists?(u1.id, h1), "dry-run job must not delete"
  end
end
