module Sync
  # Decides which versions of a node to KEEP. Pruning the rest is done by the existing
  # Sync::Gc.prune_version! mechanism — this class never deletes, it only computes a
  # keep-set (a Set of version_ids).
  #
  # Hard invariants, enforced for EVERY mode in #keep_set:
  #   - the node's current_version is ALWAYS kept (restore-to-now must work),
  #   - any version with pinned: true is ALWAYS kept.
  #
  # Modes (config via RETENTION_POLICY env; see .default):
  #   - keep_all (self-host default): keep every version, never prune. Storage is the
  #     user's own box, so unbounded history is fine.
  #   - tiered (managed): Time-Machine / Dropbox-30-day style thinning —
  #       < 24h          → keep every version
  #       1–30 days      → one per day
  #       30 days–1 year → one per week
  #       > 1 year       → one per month
  #     (Within each bucket we keep the NEWEST version of the period.)
  #
  # Make a new mode by subclassing Base and registering it in .for.
  class RetentionPolicy
    # Build the configured policy. Self-host (and tests) default to keep_all so nothing
    # is ever pruned unless an operator opts into tiered retention.
    def self.default
      self.for(mode: ENV.fetch("RETENTION_POLICY", "keep_all"))
    end

    def self.for(mode:)
      case mode.to_s
      when "keep_all" then KeepAll.new
      when "tiered"   then Tiered.new
      else raise ArgumentError, "unknown RETENTION_POLICY: #{mode.inspect}"
      end
    end

    # Common invariant enforcement. Subclasses implement #candidates_to_keep (the
    # policy-specific survivors); this wraps it to guarantee current + pinned are kept.
    class Base
      # versions: Array<Version> for ONE node. Returns a Set<String> of version_ids to keep.
      def keep_set(versions, current_version_id:, now: Time.current)
        keep = candidates_to_keep(versions, current_version_id:, now:)
        # Invariants — these can never be pruned, regardless of the tier math.
        keep << current_version_id if current_version_id
        versions.each { |v| keep << v.version_id if v.pinned? }
        keep
      end

      private

      def candidates_to_keep(_versions, current_version_id:, now:)
        raise NotImplementedError
      end
    end

    # Self-host: keep everything.
    class KeepAll < Base
      private

      def candidates_to_keep(versions, current_version_id:, now:)
        versions.map(&:version_id).to_set
      end
    end

    # Managed: tiered thinning. Bucket each version by age, keep the newest per bucket.
    class Tiered < Base
      private

      def candidates_to_keep(versions, current_version_id:, now:)
        keep = Set.new
        # Group by (tier, period-key); keep the newest version in each group.
        groups = versions.group_by { |v| bucket_key(v, now:) }
        groups.each_value do |group|
          newest = group.max_by(&:created_at)
          keep << newest.version_id
        end
        keep
      end

      # The tier decides how coarsely versions are grouped; the newest of each group survives.
      #
      # THE < 24h TIER'S KEY MUST BE UNIQUE PER VERSION, AND `created_at` IS NOT. That tier's
      # whole contract is "keep every version", which it keeps by giving each version a group of
      # its own — so the key has to be something no two versions can share. `created_at` is a
      # datetime(6) column, so two versions written inside the same microsecond have the SAME
      # value, land in one group, and `max_by(&:created_at)` keeps exactly one of them: the tier
      # that promises to thin nothing thins silently. Probed before the fix, with three tied
      # versions all under 24h, two of the three were pruned; one microsecond apart, both kept.
      #
      # `version_id` is unique BY CONSTRUCTION — a unique index on (user_id, version_id) plus a
      # model-level uniqueness validation — is never rewritten, and is already the handle
      # `Sync::Gc.prune_version!` deletes by. The older tiers deliberately DO collide across
      # versions: grouping is the entire point of a daily/weekly/monthly bucket.
      def bucket_key(version, now:)
        age = now - version.created_at
        created_at = version.created_at
        if age < 24.hours
          [ :raw, version.version_id ] # unique by construction → never thinned
        elsif age < 30.days
          [ :daily, created_at.utc.strftime("%Y-%m-%d") ]
        elsif age < 365.days
          [ :weekly, created_at.utc.strftime("%G-W%V") ] # ISO year-week
        else
          [ :monthly, created_at.utc.strftime("%Y-%m") ]
        end
      end
    end
  end
end
