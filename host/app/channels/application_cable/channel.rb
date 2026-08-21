# A FIFTH host constant: Sync::LibraryChannel says `< ::ApplicationCable::Channel` explicitly
# (engines/tinkerex-sync/app/channels/sync/library_channel.rb's own comment names this exact
# trap -- "an unqualified reference resolves correctly today only via the top-level fallback").
# Byte-identical to the host's app/channels/application_cable/channel.rb.
module ApplicationCable
  class Channel < ActionCable::Channel::Base
  end
end
