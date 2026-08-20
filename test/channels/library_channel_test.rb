require "test_helper"

class LibraryChannelTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  test "broadcast_change pushes head_seq to the user's stream" do
    user = User.create!(email: "cable@example.com")
    assert_broadcast_on(Sync::LibraryChannel.broadcasting_for(user), head_seq: 42) do
      Sync::LibraryChannel.broadcast_change(user, 42)
    end
  end
end
