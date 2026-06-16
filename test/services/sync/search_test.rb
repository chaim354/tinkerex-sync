require "test_helper"

module Sync
  # G9 — server-side name/path search over a user's nodes. Used by the web UI and a fresh
  # device with no local mirror. MUST scope to the calling user (tenant = user — never leak
  # another user's nodes), exclude tombstoned nodes by default, reconstruct the full path,
  # and paginate.
  class SearchTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "search@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    # Create a dir node directly (server tree row). Returns its node_id.
    def dir!(user: @user, name:, parent_node_id: nil)
      node_id = SecureRandom.uuid
      node = user.nodes.create!(node_id:, parent_node_id:, name:, kind: "dir")
      node_id
    end

    # Commit a file node (so it carries a version + size). Returns its node_id.
    def file!(user: @user, device: @device, name:, parent_node_id: nil, size: 5)
      node_id = SecureRandom.uuid
      cid = SecureRandom.uuid
      chunks = [ { "hash" => SecureRandom.hex(32), "offset" => 0, "length" => size } ]
      Sync::Commit.begin(user:, device:, commit_id: cid, node_id:, parent_node_id:, name:,
                         base_version_id: nil, size:, manifest: chunks)
      Sync::Commit.finalize(user:, commit_id: cid)
      node_id
    end

    test "matches a basename, case-insensitive, with full path + size" do
      proj = dir!(name: "Project")
      bracket = file!(name: "Bracket.STL", parent_node_id: proj, size: 12)
      file!(name: "notes.txt")

      hits = Sync::Search.call(user: @user, query: "bracket")[:results]
      assert_equal 1, hits.size
      h = hits.first
      assert_equal bracket, h[:node_id]
      assert_equal "Bracket.STL", h[:name]
      assert_equal "file", h[:kind]
      assert_equal "/Project/Bracket.STL", h[:path]
      assert_equal 12, h[:size]
    end

    test "matches on an interior path component (folder name)" do
      proj = dir!(name: "RobotArm")
      file!(name: "servo.step", parent_node_id: proj)
      file!(name: "loose.step")

      paths = Sync::Search.call(user: @user, query: "robotarm")[:results].map { |h| h[:path] }
      assert_includes paths, "/RobotArm"
      assert_includes paths, "/RobotArm/servo.step"
      assert_not_includes paths, "/loose.step"
    end

    test "excludes tombstoned nodes by default" do
      keep = file!(name: "keep.scad")
      drop = file!(name: "drop.scad")
      Sync::Mutation.apply(user: @user, node: @user.nodes.find_by(node_id: drop), op: "delete") { |n| n.deleted = true }

      ids = Sync::Search.call(user: @user, query: ".scad")[:results].map { |h| h[:node_id] }
      assert_includes ids, keep
      assert_not_includes ids, drop
    end

    test "include_deleted surfaces tombstoned nodes (trash search)" do
      drop = file!(name: "trashed.scad")
      Sync::Mutation.apply(user: @user, node: @user.nodes.find_by(node_id: drop), op: "delete") { |n| n.deleted = true }

      ids = Sync::Search.call(user: @user, query: "trashed", include_deleted: true)[:results].map { |h| h[:node_id] }
      assert_includes ids, drop
    end

    test "TENANT ISOLATION: user A's query never sees user B's nodes" do
      other = User.create!(email: "other@example.com")
      other_dev = Device.register!(user: other, name: "o")
      # Both users have a file with the SAME searchable name.
      mine = file!(name: "secret-design.stl")
      theirs = file!(user: other, device: other_dev, name: "secret-design.stl")

      results = Sync::Search.call(user: @user, query: "secret-design")[:results]
      ids = results.map { |h| h[:node_id] }
      assert_includes ids, mine
      assert_not_includes ids, theirs, "must NOT leak another user's node"
      assert_equal 1, results.size, "only the caller's own match"
    end

    test "respects the limit + offset (deterministic, path-ordered)" do
      10.times { |i| file!(name: format("part%02d.bin", i)) }

      page1 = Sync::Search.call(user: @user, query: "part", limit: 3, offset: 0)[:results]
      page2 = Sync::Search.call(user: @user, query: "part", limit: 3, offset: 3)[:results]
      assert_equal 3, page1.size
      assert_equal 3, page2.size
      assert_empty (page1.map { |h| h[:node_id] } & page2.map { |h| h[:node_id] }), "pages don't overlap"
    end

    test "deep nesting reconstructs the whole path (no N+1 surprise)" do
      a = dir!(name: "a")
      b = dir!(name: "b", parent_node_id: a)
      c = dir!(name: "c", parent_node_id: b)
      file!(name: "deep.gcode", parent_node_id: c)

      hits = Sync::Search.call(user: @user, query: "deep.gcode")[:results]
      assert_equal 1, hits.size
      assert_equal "/a/b/c/deep.gcode", hits.first[:path]
    end

    test "wildcard characters in the query are treated literally" do
      file!(name: "100%cotton.txt")
      file!(name: "abc.txt")
      # A '%' must match the literal percent, not act as a SQL wildcard.
      hits = Sync::Search.call(user: @user, query: "100%cotton")[:results]
      assert_equal 1, hits.size
      assert_equal "100%cotton.txt", hits.first[:name]
    end

    test "blank query returns no results (avoids dumping the whole tree)" do
      file!(name: "x.txt")
      assert_empty Sync::Search.call(user: @user, query: "")[:results]
      assert_empty Sync::Search.call(user: @user, query: "   ")[:results]
    end
  end
end
