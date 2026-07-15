module Sync
  # Best-effort advisory edit locks. `acquire` grants/refreshes the lock unless another
  # device holds an unexpired one (we never steal a live lock); the client treats a
  # not-by_me result as "someone's editing this" and either warns or just proceeds (an
  # offline or ignored lock falls through to conflict detection). TTL means a holder that
  # vanishes can't wedge the file.
  class Locks
    TTL = 5.minutes

    def self.acquire(user:, node_id:, device:, ttl: TTL)
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
      lock = user.file_locks.find_by(node_id:)
      lock.destroy if lock && lock.device_id == device.id
      true
    end

    def self.status_for(user:, node_id:, device: nil)
      lock = user.file_locks.find_by(node_id:)
      return { node_id:, held: false } unless lock && lock.expires_at > Time.current
      status(user, lock, device)
    end

    # All active locks (for the file browser's lock indicators).
    def self.active(user:)
      user.file_locks.active.map { |l| status(user, l, nil) }
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
