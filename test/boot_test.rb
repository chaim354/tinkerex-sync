require "test_helper"

# THE EMPIRICAL PROOF Stage 3b Task 9b exists to produce. Everything up to this point --
# ArchitectureInvariantsTest's two Ripper scans ("the sync engine never reaches into the maker
# layer's features", "the sync engine never names a host constant") -- is STATIC analysis: it
# proves the engine's own source text contains no forbidden reference. It cannot prove the engine
# actually BOOTS with nothing but a bare host, because no bare host had ever been built to try it
# against. This file, and the dummy app test/dummy/ it boots, is that attempt.
#
# `< ActionDispatch::IntegrationTest`, for every test here (not just the HTTP round-trip at the
# bottom): IntegrationTest is itself an ActiveSupport::TestCase, so nothing is lost, and one
# class avoids splitting "is the engine mounted" across two files for no reason.
class BootTest < ActionDispatch::IntegrationTest
  test "the sync engine's routes are mounted at /v1" do
    assert_equal({ controller: "sync/v1/tree", action: "index" },
                 Rails.application.routes.recognize_path("/v1/tree", method: :get))
  end

  # THE SINGLE MOST VALUABLE ASSERTION IN THIS TASK (per the task brief, verbatim). Every engine
  # model is namespaced under Sync:: specifically so a gem cannot squat generic top-level names
  # (CLAUDE.md §14j, Stage 3b's opening decision) -- but `isolate_namespace Sync` ALSO sets
  # `table_name_prefix` to "sync_" by Rails' own default, which would make every model look for a
  # table like "sync_versions" that has never existed in two years of migrations, three live
  # deployments, and every backup archive CLAUDE.md §14i's restore rehearsal exercises.
  # engines/tinkerex-sync/lib/tinkerex_sync/engine.rb overrides `table_name_prefix` to "" BEFORE
  # `isolate_namespace` runs specifically to prevent this -- and that override had NEVER been
  # exercised outside the one host repository whose tables happen to already be named right,
  # until this dummy app existed. A bare mount is the one place this could go wrong silently: if
  # the override's ordering were broken, `Sync::Version.table_name` would read "sync_versions",
  # every query would raise `ActiveRecord::StatementInvalid: no such table: sync_versions`, and
  # the failure would look exactly like a missing migration rather than what it actually is -- a
  # load-order bug in the engine's own namespace override.
  test "Sync::Version.table_name reads versions, not sync_versions, in a bare mount" do
    assert_equal "versions", Sync::Version.table_name
  end

  # The same property for all eight engine models -- one bad apple in the override would still
  # leave seven green if only Version were checked.
  test "every engine model resolves to its real table name, un-prefixed" do
    expected = {
      Sync::Version => "versions", Sync::Chunk => "chunks",
      Sync::ManifestChunk => "manifest_chunks", Sync::PendingCommit => "pending_commits",
      Sync::ChangelogEntry => "changelog_entries", Sync::Conflict => "conflicts",
      Sync::FileLock => "file_locks", Sync::ShareLink => "share_links"
    }
    expected.each { |model, table| assert_equal table, model.table_name, model.name }
  end

  # The engine's own models resolve, but so must the three things it declares as HOST
  # REQUIREMENTS (TinkerexSync::HOST_MODELS) -- this dummy's own stand-ins, not the real host's.
  test "the declared host models resolve to this dummy's own stand-ins" do
    assert_equal %w[User Node Device], TinkerexSync::HOST_MODELS
    assert User.instance_methods.include?(:next_seq!), "User must expose next_seq!"
    assert Device.respond_to?(:authenticate), "Device must expose .authenticate"
    assert Node.new.respond_to?(:file?), "Node must expose #file?"
  end

  # THE TWO FURTHER HOST DEPENDENCIES THIS TASK FOUND BY TRYING TO BOOT, NEITHER DECLARED BY
  # TinkerexSync::HOST_MODELS NOR GUARDED BY ArchitectureInvariantsTest::HOST_CONSTANTS: every
  # engine job says `< ::ApplicationJob` and Sync::LibraryChannel says `< ::ApplicationCable::Channel`.
  # Both are this dummy's own stand-ins (test/dummy/app/jobs/application_job.rb,
  # test/dummy/app/channels/application_cable/channel.rb) -- their mere presence on the load path
  # is not proof they were required; instantiating/subclass-checking one of each is.
  test "the engine's job and channel base classes resolve" do
    assert_kind_of ActiveJob::Base, Sync::RetentionJob.new
    assert_operator Sync::LibraryChannel, :<, ApplicationCable::Channel
  end

  # A full round trip through the mounted HTTP surface, not just constant resolution -- register
  # a device, commit a one-chunk file, read it back via /v1/tree. If this passes, the engine is
  # not merely loadable, it is FUNCTIONALLY correct end to end with nothing but this dummy behind
  # it -- verified by driving a real request, not by a green suite (CLAUDE.md §15).
  test "a device can commit a file and read it back through the mounted engine" do
    user = User.create!(email: "boot@example.com")
    device = Device.register!(user:, name: "probe")
    auth = { "Authorization" => "Bearer #{device.plaintext_token}" }

    node_id = SecureRandom.uuid
    hash = SecureRandom.hex(32)
    cid = SecureRandom.uuid
    post "/v1/commit",
         params: { commit_id: cid, node_id:, name: "hello.txt", size: 5,
                   manifest: [ { hash:, offset: 0, length: 5 } ] },
         as: :json, headers: auth
    assert_response :success

    # PUT the chunk's bytes to its presigned URL first -- Sync::Storage::MemoryChunkStore (the
    # test-env default; ChunkStore.current picks it when STORAGE_BACKEND is unset and Rails.env
    # is test) presigns to this dummy's own DevBlobsController (test/dummy/app/controllers/
    # dev_blobs_controller.rb). finalize itself defaults verify: false at the service layer
    # (Sync::Commit.finalize's own signature), so skipping this step would not have failed the
    # response either way -- it is here so this proof exercises the real byte path, not merely an
    # unverified metadata write.
    (JSON.parse(response.body)["put_urls"] || {}).each_value do |url|
      put url, params: "x", headers: { "CONTENT_TYPE" => "application/octet-stream" }
      assert_response :ok
    end

    post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth
    assert_response :success
    assert JSON.parse(response.body)["version_id"].present?

    get "/v1/tree", headers: auth
    assert_response :success
    tree = JSON.parse(response.body)["nodes"]
    assert_equal 1, tree.size
    assert_equal "hello.txt", tree.first["name"]
  end
end
