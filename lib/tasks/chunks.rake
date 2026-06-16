namespace :chunks do
  desc "Reap orphaned chunk bytes (uploaded but never finalized) from object storage. " \
       "DRY_RUN=1 reports without deleting; GRACE_HOURS overrides the in-flight grace window."
  task reap: :environment do
    dry_run = ENV["DRY_RUN"].present? && ENV["DRY_RUN"] != "0"
    grace = ENV["GRACE_HOURS"].present? ? ENV["GRACE_HOURS"].to_f.hours : Sync::ChunkReaper::PENDING_COMMIT_TTL

    if ENV["USER_ID"].present?
      user = User.find(ENV["USER_ID"])
      reaped = Sync::ChunkReaper.reap!(user, grace:, dry_run:)
      label = dry_run ? "[dry-run] would reap" : "reaped"
      puts "Sync::ChunkReaper #{label} #{reaped.size} orphan chunk(s) for user #{user.id}"
      reaped.each { |h| puts "  chunks/#{user.id}/#{h}" }
    else
      total = Sync::ChunkReaper.reap_all!(grace:, dry_run:)
      label = dry_run ? "[dry-run] would reap" : "reaped"
      puts "Sync::ChunkReaper #{label} #{total} orphan chunk(s) across all users"
    end
  end
end
