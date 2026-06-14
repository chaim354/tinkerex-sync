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

    test "release frees the lock only for its holder" do
      Sync::Locks.acquire(user: @user, node_id: @node, device: @a)
      # B's release is a no-op (not the holder).
      Sync::Locks.release(user: @user, node_id: @node, device: @b)
      assert @user.file_locks.exists?(node_id: @node), "B can't release A's lock"
      Sync::Locks.release(user: @user, node_id: @node, device: @a)
      assert_not @user.file_locks.exists?(node_id: @node), "holder releases"
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
  end
end
