# Real-time change notifications. On any commit the server broadcasts the new
# head_seq to the user's devices; each device then pulls GET /v1/changes?since=cursor.
# Coarse (one event per commit) — never per-operation.
class LibraryChannel < ApplicationCable::Channel
  BATCH_KEY = :library_channel_batch

  def subscribed
    stream_for current_user
  end

  def self.broadcast_change(user, seq)
    batch = Thread.current[BATCH_KEY]
    if batch && batch[:user_id] == user.id
      # Only the HIGHEST seq matters: a device pulls everything since its own cursor, so one
      # nudge carrying the final head_seq subsumes every nudge that would have preceded it.
      batch[:seq] = seq if batch[:seq].nil? || seq > batch[:seq]
      return
    end

    broadcast_to(user, { head_seq: seq })
  end

  # COLLAPSE A BULK OPERATION'S NUDGES INTO ONE, which is what this class's own header has always
  # claimed it does ("never per-operation") and what a sweep was violating.
  #
  # Maker::ProjectIntake files each file through Maker::MoveNode, and each move is its own
  # Sync::Mutation.apply — so filing 25 files broadcast 26 times (25 moves plus one per category
  # subfolder Maker::LibraryFolder.ensure_path! had to create). On managed Postgres a 500-file
  # sweep is 500 serialized user-row locks, 500 Solid Cable inserts and 500 nudges per device, to
  # tell every device something one message already says. Devices converged fine — pull is
  # incremental — so this is pure server-side waste, which is exactly why it survived so long.
  #
  # WHAT THIS DOES NOT DO: batch the MUTATIONS. Each move still takes its own lock and writes its
  # own changelog entry; only the notification is coalesced. Batching the writes is a much larger
  # change to Sync::Mutation and is not what the cost here is.
  #
  # FLUSHES ON THE WAY OUT EVEN IF THE BLOCK RAISED, and that is a correctness point rather than
  # tidiness: the moves that already happened are COMMITTED (each in its own transaction), so
  # swallowing their nudge would leave every device unaware of real changes until something else
  # happened to broadcast. A half-finished sweep still has to be announced.
  #
  # NESTING JOINS rather than nests: Maker::ProjectIntake wraps its per-project run, and the
  # per-user sweep wraps the loop over projects, so an inner batch for the same user simply
  # contributes to the outer one and the whole user sweep emits a single nudge. A batch for a
  # DIFFERENT user is not a shape this app produces (every entry point is user-scoped), but it is
  # handled honestly anyway — the id check means such a call broadcasts immediately rather than
  # being silently absorbed into someone else's batch.
  def self.batch(user)
    outer = Thread.current[BATCH_KEY]
    return yield if outer && outer[:user_id] == user.id

    Thread.current[BATCH_KEY] = { user_id: user.id, seq: nil }
    begin
      yield
    ensure
      batch = Thread.current[BATCH_KEY]
      Thread.current[BATCH_KEY] = outer
      broadcast_to(user, { head_seq: batch[:seq] }) if batch && batch[:seq]
    end
  end
end
