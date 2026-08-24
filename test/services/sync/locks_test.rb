require "test_helper"

module Sync
  # Best-effort advisory edit locks: a connected client acquires one so other connected
  # clients can avoid colliding; it never blocks (offline skips it), and a TTL frees a
  # vanished holder's lock.
  class LocksTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "lock@example.com")
      @a = Device.register!(user: @user, name: "laptop")
      @b = Device.register!(user: @user, name: "workshop-pi")
      @node = SecureRandom.uuid
      @user.nodes.create!(node_id: @node, name: "locked.txt", kind: "file")
    end

    test "acquire grants a free lock to the requesting device" do
      s = Sync::Locks.acquire(user: @user, node_id: @node, device: @a)
      assert s[:held]
      assert s[:by_me]
      assert_equal "laptop", s[:device_name]
    end

    test "another device sees the lock as held, not by_me, and does not steal it" do
      Sync::Locks.acquire(user: @user, node_id: @node, device: @a)
      s = Sync::Locks.acquire(user: @user, node_id: @node, device: @b)
      assert s[:held]
      assert_not s[:by_me], "B must not steal A's live lock"
      assert_equal "laptop", s[:device_name], "still reports A as the holder"
    end

    test "the holder can refresh its own lock (extends the TTL)" do
      Sync::Locks.acquire(user: @user, node_id: @node, device: @a)
      old = @user.file_locks.find_by(node_id: @node).expires_at
      travel 1.minute do
        s = Sync::Locks.acquire(user: @user, node_id: @node, device: @a)
        assert s[:by_me]
        assert_operator @user.file_locks.find_by(node_id: @node).expires_at, :>, old
      end
    end

    test "an expired lock is reclaimable by any device" do
      Sync::Locks.acquire(user: @user, node_id: @node, device: @a, ttl: 1.second)
      travel 2.seconds do
        s = Sync::Locks.acquire(user: @user, node_id: @node, device: @b)
        assert s[:by_me], "B reclaims A's expired lock"
        assert_equal "workshop-pi", s[:device_name]
      end
    end

    test "release frees the lock only for its holder, and says so honestly in its return value" do
      Sync::Locks.acquire(user: @user, node_id: @node, device: @a)
      # B's release is a no-op (not the holder) -- and MUST report that, not a blanket true.
      s = Sync::Locks.release(user: @user, node_id: @node, device: @b)
      assert_equal({ released: false }, s, "B never held it, so nothing was released")
      assert @user.file_locks.exists?(node_id: @node), "B can't release A's lock"
      s = Sync::Locks.release(user: @user, node_id: @node, device: @a)
      assert_equal({ released: true }, s, "A held it, so this release was real")
      assert_not @user.file_locks.exists?(node_id: @node), "holder releases"
    end

    test "releasing a node with no lock at all is also an honest no-op, not an error" do
      s = Sync::Locks.release(user: @user, node_id: @node, device: @a)
      assert_equal({ released: false }, s)
    end

    test "status_for and active reflect only unexpired locks" do
      Sync::Locks.acquire(user: @user, node_id: @node, device: @a, ttl: 1.second)
      assert Sync::Locks.status_for(user: @user, node_id: @node)[:held]
      assert_equal 1, Sync::Locks.active(user: @user).size
      travel 2.seconds do
        assert_not Sync::Locks.status_for(user: @user, node_id: @node)[:held]
        assert_empty Sync::Locks.active(user: @user)
      end
    end

    test "active reports by_me for the device passed in, and false when none is passed" do
      Sync::Locks.acquire(user: @user, node_id: @node, device: @a)
      assert Sync::Locks.active(user: @user, device: @a).first[:by_me], "A is the holder"
      assert_not Sync::Locks.active(user: @user, device: @b).first[:by_me], "B is not"
      assert_not Sync::Locks.active(user: @user).first[:by_me],
                 "no device passed at all -- the pre-fix default -- still answers false, never a stale true"
    end

    test "acquire raises for a node_id nothing ever created, rather than minting a lock for it" do
      never_created = SecureRandom.uuid
      assert_raises(ActiveRecord::RecordNotFound) do
        Sync::Locks.acquire(user: @user, node_id: never_created, device: @a)
      end
      assert_not @user.file_locks.exists?(node_id: never_created)
    end

    test "release raises for a node_id nothing ever created" do
      never_created = SecureRandom.uuid
      assert_raises(ActiveRecord::RecordNotFound) do
        Sync::Locks.release(user: @user, node_id: never_created, device: @a)
      end
    end

    test "a tombstoned node is not lockable -- liveness, not mere table presence, is the bar" do
      deleted_id = SecureRandom.uuid
      @user.nodes.create!(node_id: deleted_id, name: "gone.txt", kind: "file", deleted: true)
      assert_raises(ActiveRecord::RecordNotFound) do
        Sync::Locks.acquire(user: @user, node_id: deleted_id, device: @a)
      end
    end

    test "unlock on a tombstoned node also raises -- the same live-node check as acquire" do
      deleted_id = SecureRandom.uuid
      @user.nodes.create!(node_id: deleted_id, name: "gone.txt", kind: "file", deleted: true)
      assert_raises(ActiveRecord::RecordNotFound) do
        Sync::Locks.release(user: @user, node_id: deleted_id, device: @a)
      end
    end

    test "deleting a node out from under a live lock does not itself raise on the lock side" do
      # SubtreeDelete never touches file_locks (checked: grep app/ lib/ for file_locks finds only
      # this class and its two controllers) -- tombstoning a node currently locked leaves the lock
      # row sitting there, orphaned, until its TTL lapses. Documented here, not fixed here: the fix
      # this class controls is refusing a NEW lock/unlock against a tombstone, not reaching into
      # SubtreeDelete to sweep an old one. A future lock-cleanup-on-delete is a SubtreeDelete change,
      # not a Locks one.
      Sync::Locks.acquire(user: @user, node_id: @node, device: @a)
      @user.nodes.find_by(node_id: @node).update!(deleted: true)
      assert @user.file_locks.exists?(node_id: @node), "the row survives the tombstone, orphaned"
      assert_raises(ActiveRecord::RecordNotFound) do
        Sync::Locks.acquire(user: @user, node_id: @node, device: @a)
      end
    end
  end
end
