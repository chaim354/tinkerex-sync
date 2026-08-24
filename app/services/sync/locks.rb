module Sync
  # Best-effort advisory edit locks. `acquire` grants/refreshes the lock unless another
  # device holds an unexpired one (we never steal a live lock); the client treats a
  # not-by_me result as "someone's editing this" and either warns or just proceeds (an
  # offline or ignored lock falls through to conflict detection). TTL means a holder that
  # vanishes can't wedge the file.
  class Locks
    TTL = 5.minutes

    def self.acquire(user:, node_id:, device:, ttl: TTL)
      # LIVE, not merely present-in-the-table -- `.present` is this codebase's one spelling of
      # "live node" (FileLayer::Chunk, Sync::Tree, Sync::SubtreeDelete all read it the same way),
      # reused here rather than inventing a second one that could drift from it. A tombstoned
      # node has nothing left to edit, so locking one is meaningless; worse, nothing anywhere
      # destroys a FileLock when its node is deleted (grep app/ lib/ for file_locks — the only
      # hits are this class and its two controllers), so a lock that COULD be taken out on a
      # tombstone would just sit there, outliving the thing it was guarding -- the same
      # accumulation shape this codebase already treats as a bug wherever else it has found it.
      # A restore-then-edit flow is unaffected: undelete clears the tombstone before anyone can
      # reach the node again to lock it.
      #
      # Raises ActiveRecord::RecordNotFound for BOTH a node_id nothing ever created AND a
      # tombstoned one -- deliberately the SAME exception, mapped by BaseController to the SAME
      # 404 body, so this endpoint cannot be used as an oracle for which node ids were ever real.
      user.nodes.present.find_by!(node_id:)

      now = Time.current
      lock = user.file_locks.find_or_initialize_by(node_id:)
      held_by_other = lock.persisted? && lock.expires_at > now && lock.device_id != device.id
      unless held_by_other
        lock.assign_attributes(device_id: device.id, expires_at: now + ttl)
        lock.save!
      end
      status(user, lock.reload, device)
    rescue ActiveRecord::RecordNotUnique
      # Two devices raced to CREATE the lock for the same node_id (the unique index rejected the
      # loser's INSERT). That's benign: the row now exists. Re-read it and report status — the
      # loser simply didn't win the lock this round, exactly as if the other device held it.
      lock = user.file_locks.find_by(node_id:)
      lock ? status(user, lock, device) : { node_id:, held: false }
    end

    def self.release(user:, node_id:, device:)
      # Same live-node check as acquire, same reasoning: a tombstoned node gets the identical
      # 404 an unknown node_id gets, not a pass.
      user.nodes.present.find_by!(node_id:)

      lock = user.file_locks.find_by(node_id:)
      released = lock.present? && lock.device_id == device.id
      # Report what actually happened rather than a blanket `true`. These locks are advisory
      # and best-effort (this class's own header comment), so a device that asks to release a
      # lock it never held -- because another device holds it, or it already expired, or it was
      # never taken out -- has not done anything wrong; `released: false` says so honestly
      # instead of erroring, and instead of the previous unconditional `true`, which claimed a
      # release that never happened and left a caller with no way to notice its unlock was a
      # no-op.
      lock.destroy if released
      { released: }
    end

    def self.status_for(user:, node_id:, device: nil)
      lock = user.file_locks.find_by(node_id:)
      return { node_id:, held: false } unless lock && lock.expires_at > Time.current
      status(user, lock, device)
    end

    # All active locks (for the file browser's lock indicators). `device:` is what lets a
    # caller learn which of these locks is its OWN; omitted (nil, the default -- same default
    # status_for already used), every lock reports by_me: false, same as passing no device to
    # #status directly. Previously hardcoded nil unconditionally, so GET /v1/locks could never
    # answer "is this mine" for anyone, even the actual holder.
    def self.active(user:, device: nil)
      user.file_locks.active.map { |l| status(user, l, device) }
    end

    def self.status(user, lock, device)
      {
        node_id: lock.node_id,
        held: true,
        by_me: device.present? && lock.device_id == device.id,
        device_name: user.devices.find_by(id: lock.device_id)&.name || "another device",
        expires_at: lock.expires_at
      }
    end
  end
end
