require "test_helper"

module Sync
  # Offline-edit divergence: a device commits an edit based on a version that's no longer
  # current. Instead of silently last-writer-wins, we record both sides and let the user
  # keep one or split into two.
  class ConflictsTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "conflict@example.com")
      @dev_a = Device.register!(user: @user, name: "laptop")
      @dev_b = Device.register!(user: @user, name: "workshop-pi")
      @node_id = SecureRandom.uuid
    end

    # Commit a version of @node_id from `device`, based on `base`. Returns the version.
    def commit!(device:, body:, base: nil)
      cid = SecureRandom.uuid
      chunks = [ { "hash" => Digest::SHA256.hexdigest(body), "offset" => 0, "length" => body.bytesize } ]
      Sync::Commit.begin(user: @user, device:, commit_id: cid, node_id: @node_id,
                         parent_node_id: nil, name: "part.scad", base_version_id: base,
                         size: body.bytesize, manifest: chunks)
      Sync::Commit.finalize(user: @user, commit_id: cid).first
    end

    test "an edit based on the current version is a clean put (no conflict)" do
      v1 = commit!(device: @dev_a, body: "one")
      v2 = commit!(device: @dev_b, body: "two", base: v1.version_id)
      assert_empty @user.conflicts.unresolved
      assert_equal v2.version_id, @user.nodes.find_by(node_id: @node_id).current_version_id
      assert_equal "put", @user.changelog_entries.order(:seq).last.op
    end

    test "an edit based on a stale version raises a conflict instead of LWW" do
      v1 = commit!(device: @dev_a, body: "one")
      commit!(device: @dev_a, body: "two", base: v1.version_id) # advances current to v2
      stale = commit!(device: @dev_b, body: "offline edit", base: v1.version_id) # B based on v1

      conflict = @user.conflicts.unresolved.find_by(node_id: @node_id)
      assert conflict, "a conflict is recorded"
      assert_equal stale.version_id, conflict.incoming_version_id
      # The node is NOT silently overwritten — it stays at v2 until the user decides.
      assert_not_equal stale.version_id, @user.nodes.find_by(node_id: @node_id).current_version_id
      assert_equal "conflict", @user.changelog_entries.order(:seq).last.op
    end

    test "a stale base from the SAME device fast-forwards (its own write racing its echo, not a conflict)" do
      # The sync daemon can push a change, pull its own changelog entry back (advancing
      # current_version), then a follow-up/retry push still carries the pre-echo base. That's not a
      # real divergence — only a *different* device moving current_version is a conflict.
      v1 = commit!(device: @dev_a, body: "one")
      v2 = commit!(device: @dev_a, body: "two", base: v1.version_id) # current advances to v2 (dev_a)
      v3 = commit!(device: @dev_a, body: "three", base: v1.version_id) # stale base, but SAME device

      assert_empty @user.conflicts.unresolved, "same-device stale base is not a conflict"
      assert_equal v3.version_id, @user.nodes.find_by(node_id: @node_id).current_version_id,
                   "the node fast-forwards to the same device's newer version"
      assert_equal "put", @user.changelog_entries.order(:seq).last.op
      assert v2.version_id # (v2 is the intervening same-device version)
    end

    test "list reports both sides with device + time so the client can prompt" do
      v1 = commit!(device: @dev_a, body: "one")
      commit!(device: @dev_a, body: "two", base: v1.version_id)
      commit!(device: @dev_b, body: "offline", base: v1.version_id)

      list = Sync::Conflicts.list(user: @user)
      assert_equal 1, list.size
      c = list.first
      assert_equal "part.scad", c[:name]
      assert_equal "laptop", c[:current][:device_name]
      assert_equal "workshop-pi", c[:incoming][:device_name]
      assert c[:current][:created_at].present? && c[:incoming][:created_at].present?
    end

    test "keep resolves the conflict and makes the chosen version current" do
      v1 = commit!(device: @dev_a, body: "one")
      v2 = commit!(device: @dev_a, body: "two", base: v1.version_id)
      incoming = commit!(device: @dev_b, body: "offline", base: v1.version_id)

      seq = Sync::Conflicts.keep(user: @user, node_id: @node_id, version_id: incoming.version_id)
      assert_empty @user.conflicts.unresolved, "conflict resolved"
      assert_equal incoming.version_id, @user.nodes.find_by(node_id: @node_id).current_version_id
      assert_equal seq, @user.reload.head_seq
      assert_equal "put", @user.changelog_entries.order(:seq).last.op
      # v2 isn't destroyed — it's still in history.
      assert @user.versions.exists?(version_id: v2.version_id)
    end

    test "keep rejects a version that isn't part of the conflict" do
      v1 = commit!(device: @dev_a, body: "one")
      commit!(device: @dev_a, body: "two", base: v1.version_id)
      commit!(device: @dev_b, body: "offline", base: v1.version_id)
      assert_raises(ArgumentError) do
        Sync::Conflicts.keep(user: @user, node_id: @node_id, version_id: SecureRandom.uuid)
      end
    end

    test "split keeps both: the incoming becomes a new sibling reusing its chunks" do
      v1 = commit!(device: @dev_a, body: "one")
      v2 = commit!(device: @dev_a, body: "kept current", base: v1.version_id)
      incoming = commit!(device: @dev_b, body: "the other edit", base: v1.version_id)
      ref_before = @user.chunks.find_by(chunk_hash: Digest::SHA256.hexdigest("the other edit")).refcount

      new_node_id, = Sync::Conflicts.split(user: @user, node_id: @node_id)

      assert_empty @user.conflicts.unresolved
      # Original node still points at the current version...
      assert_equal v2.version_id, @user.nodes.find_by(node_id: @node_id).current_version_id
      # ...and a new sibling file exists with the incoming content.
      copy = @user.nodes.find_by(node_id: new_node_id)
      assert copy, "a conflicted-copy node was created"
      assert_includes copy.name, "conflict from workshop-pi"
      assert_equal incoming.manifest_id, copy.current_version.manifest_id, "reuses the incoming manifest"
      # Chunks reused (refcount bumped), not re-uploaded.
      assert_equal ref_before + 1, @user.chunks.find_by(chunk_hash: Digest::SHA256.hexdigest("the other edit")).refcount
    end
  end
end
