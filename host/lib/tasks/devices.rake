# frozen_string_literal: true

# MINTS THE FIRST DEVICE TOKEN. There is no password login on this host (see V1::DevicesController),
# so this is how a client gets its first credential -- an operator action, like any other server
# secret, and the same shape as the deploy key a private gem needs.
#
# THE TOKEN IS PRINTED ONCE AND NEVER STORED IN PLAINTEXT: Device keeps only a SHA256 digest, so a
# lost token is re-issued rather than recovered. Redirect it to a password manager, not to a file.
namespace :sync do
  namespace :device do
    desc "Issue a device token for a user (EMAIL=, NAME=). Creates the user if absent."
    task issue: :environment do
      email = ENV["EMAIL"].presence or abort "EMAIL= is required"
      user = User.find_or_create_by!(email:)
      device = Device.register!(user:, name: ENV.fetch("NAME", "device"))

      puts "user_id:      #{user.id}"
      puts "device_id:    #{device.id}"
      puts "device_token: #{device.plaintext_token}"
      puts
      puts "Store it now -- only its digest is kept, so this cannot be shown again."
    end

    desc "List a user's devices (EMAIL=), without revealing any token"
    task list: :environment do
      email = ENV["EMAIL"].presence or abort "EMAIL= is required"
      user = User.find_by!(email:)
      user.devices.order(:id).each { |d| puts "#{d.id}\t#{d.name}\tlast seen #{d.last_seen_at || "never"}" }
    end
  end
end
