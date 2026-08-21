require "test_helper"

module V1
  # Trash / undelete over the v1 API: list tombstoned nodes, restore one (which
  # un-tombstones + appends a changelog entry so other devices converge), and
  # cross-user isolation (you can't see or restore another user's trash).
  class TrashFlowTest < ActionDispatch::IntegrationTest
    # THE CHUNK TRASH, which is the only thing this controller ever was: a tombstone whose versions
    # are kept, restored by re-pointing at one. A share/s3 library's trash is a different mechanism
    # (2b: bytes to `.trash/<node_id>/`, recovered via FileLayer#undelete) and is not exposed here,
    # so Phase 4 Task 7 gates this surface on `syncable` -- this suite says which trash it means.
    #
    # `pin_file_layer_backend("chunk")` DROPPED WHEN THIS TEST MOVED HERE -- see
    # tenant_isolation_test.rb's setup for the full argument.
    setup do
      Sync::Storage::ChunkStore.reset!
    end

    def register(email:, name: "laptop")
      bootstrap_token(email: email, device_name: name)
    end

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    def commit_file(token, name:, node_id: SecureRandom.uuid, hash: "1" * 64)
      cid = SecureRandom.uuid
      post "/v1/commit",
           params: { commit_id: cid, node_id:, parent_node_id: nil, name:, base_version_id: nil,
                     size: 5, manifest: [ { hash:, offset: 0, length: 5 } ] },
           as: :json, headers: auth(token)
      assert_response :success
      (JSON.parse(response.body)["put_urls"] || {}).each_value do |url|
        put url, params: "x", headers: { "CONTENT_TYPE" => "application/octet-stream" }
      end
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :success
      node_id
    end

    test "delete -> trash lists it -> restore brings it back" do
      token = register(email: "trash-api@example.com")
      node_id = commit_file(token, name: "part.stl")

      delete "/v1/nodes/#{node_id}", headers: auth(token)
      assert_response :success

      get "/v1/trash", headers: auth(token)
      assert_response :success
      items = JSON.parse(response.body)["items"]
      assert_equal 1, items.size
      assert_equal node_id, items.first["node_id"]
      assert_equal "part.stl", items.first["name"]
      assert_equal 5, items.first["size"]
      assert items.first["deleted_at"].present?

      post "/v1/trash/#{node_id}/restore", as: :json, headers: auth(token)
      assert_response :success
      assert JSON.parse(response.body)["seq"]

      # Back in the live tree; trash is now empty.
      get "/v1/tree", headers: auth(token)
      assert_response :success
      assert(JSON.parse(response.body)["nodes"].any? { |n| n["node_id"] == node_id })

      get "/v1/trash", headers: auth(token)
      assert_empty JSON.parse(response.body)["items"]
    end

    test "restore appends a changelog entry so other devices converge" do
      token = register(email: "trash-cl@example.com")
      node_id = commit_file(token, name: "f.bin")
      delete "/v1/nodes/#{node_id}", headers: auth(token)

      get "/v1/changes", params: { since: 0 }, headers: auth(token)
      cursor = JSON.parse(response.body)["changes"].last["seq"]

      post "/v1/trash/#{node_id}/restore", as: :json, headers: auth(token)
      assert_response :success

      get "/v1/changes", params: { since: cursor }, headers: auth(token)
      changes = JSON.parse(response.body)["changes"]
      assert_equal 1, changes.size
      assert_equal "put", changes.first["op"]
      assert_equal node_id, changes.first["node_id"]
    end

    test "restoring an orphaned node returns 409 unless to_root" do
      token = register(email: "trash-orphan@example.com")
      dir_id = SecureRandom.uuid
      post "/v1/nodes", params: { node_id: dir_id, name: "Projects" }, as: :json, headers: auth(token)
      assert_response :created
      child = commit_file(token, name: "child.stl")
      # Move child under the dir, then delete both.
      post "/v1/nodes/#{child}/move", params: { new_parent_node_id: dir_id }, as: :json, headers: auth(token)
      delete "/v1/nodes/#{child}", headers: auth(token)
      delete "/v1/nodes/#{dir_id}", headers: auth(token)

      post "/v1/trash/#{child}/restore", as: :json, headers: auth(token)
      assert_response :conflict
      assert_equal "parent_deleted", JSON.parse(response.body)["error"]

      post "/v1/trash/#{child}/restore", params: { to_root: true }, as: :json, headers: auth(token)
      assert_response :success
      assert_nil JSON.parse(response.body)["parent_node_id"]
    end

    test "isolation: a user cannot see or restore another user's trash" do
      alice = register(email: "alice-trash@example.com")
      alice_node = commit_file(alice, name: "secret.stl")
      delete "/v1/nodes/#{alice_node}", headers: auth(alice)

      bob = register(email: "bob-trash@example.com")

      # Bob's trash is empty — never alice's tombstone.
      get "/v1/trash", headers: auth(bob)
      assert_empty JSON.parse(response.body)["items"]

      # Bob can't restore alice's node.
      post "/v1/trash/#{alice_node}/restore", as: :json, headers: auth(bob)
      assert_response :not_found

      # And it's still deleted for alice.
      get "/v1/trash", headers: auth(alice)
      assert_equal 1, JSON.parse(response.body)["items"].size
    end

    # SCHEMA/TRANSACTION and PRAGMA are excluded — they are this endpoint's cost only by accident
    # of being first in the process, and the warm-up request below is what really keeps them out.
    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
          n += 1
        end
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # A TOMBSTONE SHAPED LIKE A REAL ONE — `current_version_id` IS ALWAYS SET, which is the
    # load-bearing part (see the trap in the test below). `size` lives on the VERSION, not on the
    # node, because that is where the serializer reads it from (TrashController#index:
    # `sizes[n.current_version_id]`, never `n.size`). `with_version: false` points the tombstone
    # at a version id this user does not hold, which is the cross-tenant case.
    #
    # `nodes.create!` DOES NOT PASS `size:` HERE, unlike the host's copy of this helper -- this
    # dummy's Node has no `size` column at all (test/dummy/app/models/node.rb's own header:
    # grepped every engine reference to `node.size` before writing that schema; there are none).
    # Confirmed inert before dropping it, not assumed: the comment above already states the
    # serializer never reads it, and this dummy's minimal nodes table is the enforcement of that
    # claim rather than a second copy of it.
    def tombstone!(user, id, version_id: "v-#{id}", version_size: 7, with_version: true)
      user.versions.create!(version_id:, node_id: id, manifest_id: "m-#{id}", size: version_size) if with_version
      user.nodes.create!(node_id: id, name: "#{id}.stl", kind: "file",
                         mtime: 1_700_000_000_000_000_000, deleted: true,
                         current_version_id: version_id)
    end

    # THE QUERY COST OF `GET /v1/trash`, WHICH NOTHING ASSERTED UNTIL 2026-08-19.
    #
    # There is no pagination here and the list is unbounded — `FileLayer::Chunk#trashed`, serving
    # the same rows through the port, calls it "every file the user ever deleted". `#index` used to
    # call `n.current_version` per row, a `find_by` that `includes` cannot reach (§14a: there is no
    # AR association on the string `version_id`), and measured **4 + N**: N=1 → 5, N=5 → 9,
    # N=25 → 29. The web `trash#index` was batched and budget-guarded from the start; the v1 API
    # serving the same rows was neither.
    #
    # THE TRAP, AND IT IS THE ENTIRE REASON THIS SEEDS `current_version_id`: `Node#current_version`
    # returns nil WITHOUT QUERYING when that column is blank. Seeded the way
    # `page_query_budget_test.rb`'s web-trash guard seeds it — bare `nodes.create!`, no version id
    # — this endpoint measures a flat 4 at N=5 **and** at N=25 *with the fix removed*: a guard
    # that goes green over the live N+1 it exists to forbid. That web guard is structurally blind
    # for exactly this reason; noted, not fixed here.
    #
    # CONSTANCY IN N, NEVER A LITERAL (§14e) — a literal pins whatever the endpoint costs today.
    test "GET /v1/trash does not grow with the number of tombstones" do
      token = register(email: "trash-budget@example.com")
      user = User.find_by(email: "trash-budget@example.com")

      get "/v1/trash", headers: auth(token) # warm every lazy load before measuring
      assert_response :success

      3.times { |i| tombstone!(user, "small#{i}") }
      small = count_queries { get "/v1/trash", headers: auth(token) }
      assert_equal 3, JSON.parse(response.body)["items"].size

      12.times { |i| tombstone!(user, "large#{i}") }
      large = count_queries { get "/v1/trash", headers: auth(token) }
      items = JSON.parse(response.body)["items"]
      assert_equal 15, items.size
      assert(items.all? { |i| i["size"] == 7 }, "every tombstone must still report its size")

      assert_equal small, large,
                   "GET /v1/trash issued #{small} queries over 3 tombstones and #{large} over 15 " \
                   "— it grows with the data. Batch the version lookup."
    end

    # THE BATCH LOAD IS `user.versions`, AND DROPPING THE `user.` IS BOTH A TENANCY HOLE AND A FULL
    # TABLE SCAN. A `version_id` carries no user salt, so an unscoped `Version.where(version_id:)`
    # returns a STRANGER'S ROW rather than none — and `versions` is indexed on
    # `(user_id, version_id)` with nothing on `version_id` alone, so the unscoped form plans as
    # `SCAN versions` (verified with EXPLAIN QUERY PLAN) on the largest sync table.
    #
    # A SINGLE-USER TEST CANNOT SEE ANY OF THAT, which is why a stranger holds rows here under the
    # SAME `version_id` strings. The nil arm is the deterministic one: this user has no row for
    # `shared-nowhere`, so unscoped it would report the stranger's 999 where the truth is nil.
    test "GET /v1/trash reads only this user's versions, never a stranger's row with the same version_id" do
      token = register(email: "trash-scope@example.com")
      user = User.find_by(email: "trash-scope@example.com")
      stranger = User.find_by(email: "trash-scope-other@example.com") ||
                 # No confirmed_at:/omniauth_signup: -- see test/models/share_link_test.rb's setup.
                 User.create!(email: "trash-scope-other@example.com")

      tombstone!(user, "mine", version_id: "shared-vid", version_size: 7)
      stranger.versions.create!(version_id: "shared-vid", node_id: "theirs", manifest_id: "m-x",
                                size: 999)

      # A tombstone pointing at a version id ONLY the stranger holds: the honest answer is nil.
      stranger.versions.create!(version_id: "shared-nowhere", node_id: "theirs2", manifest_id: "m-y",
                                size: 999)
      tombstone!(user, "orphan", version_id: "shared-nowhere", with_version: false)

      get "/v1/trash", headers: auth(token)
      assert_response :success
      by_node = JSON.parse(response.body)["items"].index_by { |i| i["node_id"] }
      assert_equal 7, by_node["mine"]["size"], "must report THIS user's version size, not 999"
      assert_nil by_node["orphan"]["size"],
                 "a version id only another user holds must read as nil, not as their size"
    end

    # A TOMBSTONE WITH NO VERSION TO LOOK UP STILL SERIALIZES — `size: nil`, never a raise and
    # never a missing key. Two shapes reach this: a directory (which never had a
    # `current_version_id`) and a file whose version row is gone. `sizes[...]` answers nil for
    # both, which is byte-identical to what the old `v&.size` said.
    #
    # THIS IS NOT A GUARD ON `Sync.load_version_sizes`' `return {} if ids.empty?`, AND NO
    # QUERY-COUNT TEST COULD BE. That line saves nothing: probed here, `where(version_id: []).pluck`
    # issues ZERO queries because Rails short-circuits an empty IN-list before the adapter sees it,
    # so the version-less trash costs 4 with the early return and 4 without it. Asserting a
    # difference there would be a test that passes whatever the code does — this repo's dominant
    # failure shape. What is asserted instead is the behaviour that does exist.
    test "a tombstone with no resolvable version serializes with a nil size" do
      token = register(email: "trash-empty@example.com")
      user = User.find_by(email: "trash-empty@example.com")

      user.nodes.create!(node_id: "d0", name: "Projects", kind: "dir", deleted: true,
                         mtime: 1_700_000_000_000_000_000)
      tombstone!(user, "gone", with_version: false) # points at a version row that does not exist

      get "/v1/trash", headers: auth(token)
      assert_response :success
      by_node = JSON.parse(response.body)["items"].index_by { |i| i["node_id"] }
      assert_equal 2, by_node.size
      assert_nil by_node["d0"]["size"]
      assert_nil by_node["gone"]["size"]
      # The version id is still published even though nothing resolves it — an unchanged field.
      assert_equal "v-gone", by_node["gone"]["version_id"]
    end
  end
end
