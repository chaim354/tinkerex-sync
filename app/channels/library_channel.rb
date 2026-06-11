# Real-time change notifications. On any commit the server broadcasts the new
# head_seq to the user's devices; each device then pulls GET /v1/changes?since=cursor.
# Coarse (one event per commit) — never per-operation.
class LibraryChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user
  end

  def self.broadcast_change(user, seq)
    broadcast_to(user, { head_seq: seq })
  end
end
