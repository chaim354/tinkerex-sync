# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "pathname"

# bin/build-and-push's TAGGING is what the cutover leaned on and what every deploy still leans on
# (docs/superpowers/plans/2026-10-07-rust-cutover.md §0.3.3): `:latest` is what the maker app's
# `sync` accessory pulls on its next reboot, so a build that moves it ARMS a deploy. The revision
# tag keeps its `-rust` suffix after Phase 6 removed the Ruby image, so the `:<sha>-rust` tags
# pushed during the cutover keep meaning what they meant. These drive the REAL script with a
# recording `docker` shim on PATH and read back the one `buildx build` call it makes -- the wire,
# not a re-derivation of the script's arithmetic.
class BuildAndPushTest < Minitest::Test
  ROOT   = Pathname.new(File.expand_path("..", __dir__))
  SCRIPT = ROOT.join("bin/build-and-push")
  REPO   = "ghcr.io/chaim354/tinkerex-sync"
  REVISION_TAG = /\A#{Regexp.escape(REPO)}:[0-9a-f]{40}(-dirty)?-rust\z/

  test "SYNC_PUSH_LATEST=0 pushes the -rust revision tag and leaves :latest alone" do
    # SYNC_IMPL=rust is the cutover plan's own spelling of this command (§2.4); it still works.
    out, status, build, calls = run_script("SYNC_IMPL" => "rust", "SYNC_PUSH_LATEST" => "0")

    assert status.success?, out
    refute_nil build, "expected one `docker buildx build`, got: #{calls.inspect}"
    assert_includes build, "-f Dockerfile.rust"
    assert_includes build, "--label org.opencontainers.image.description=tinkerex-sync (rust)"
    assert_includes build, "--push"

    tags = tags_of(build)
    assert_equal 1, tags.size, "exactly one tag, got #{tags.inspect}"
    assert_match REVISION_TAG, tags.first
    assert_match(/left #{Regexp.escape(REPO)}:latest untouched/, out)
    assert_match(/imagetools create -t #{Regexp.escape(REPO)}:latest #{Regexp.escape(tags.first)}/, out,
                 "the promote command is printed, naming the tag just pushed")
  end

  test "the default build is the Rust server and moves :latest beside a :<sha>-rust tag, with SYNC_IMPL unset" do
    # The bare invocation is the one that broke: `set -u` plus a bare `$SYNC_IMPL` in the label exited
    # "unbound variable" after docker login. SYNC_IMPL is explicitly UNSET here.
    #
    # It is also the invocation an operator types without thinking, so it must build what production
    # runs. Until 2026-10-14 it built the RUBY image and moved :latest, a week after production cut
    # over to Rust: a bare run followed by `kamal accessory reboot sync` rolled production back,
    # silently (the readiness audit's footgun, the maker repo's docs/AUDIT-2026-10-12-readiness.md
    # §2.4.2). Since Phase 6 there is no Ruby image left to build at all.
    out, status, build, calls = run_script({})

    assert status.success?, out
    refute_nil build, "expected one `docker buildx build`, got: #{calls.inspect}"
    assert_includes build, "-f Dockerfile.rust"
    assert_includes build, "--label org.opencontainers.image.description=tinkerex-sync (rust)"

    tags = tags_of(build)
    assert_equal 2, tags.size, tags.inspect
    assert_includes tags, "#{REPO}:latest"
    revision = (tags - [ "#{REPO}:latest" ]).first
    assert_match REVISION_TAG, revision
    assert_match(/pushed #{Regexp.escape(REPO)}:latest -> #{Regexp.escape(revision)}/, out)
  end

  test "SYNC_IMPL=ruby is refused by name, pointing at the retag rollback, before docker is touched" do
    # The cutover plan's rollback notes still say `SYNC_IMPL=ruby bin/build-and-push`. Phase 6 deleted
    # the Ruby, so that command cannot mean what it says -- and IGNORING it would build the Rust image
    # and move :latest while the operator believed they had rebuilt the rollback. The rollback needs
    # no build: it is a retag of the pinned ruby-<R> image (cutover plan §6).
    out, status, _build, calls = run_script("SYNC_IMPL" => "ruby")

    assert_equal 2, status.exitstatus, out
    assert_includes out, "SYNC_IMPL='ruby'"
    assert_includes out, "ruby-<R>"
    assert_empty calls, "a refused build must not even log in: #{calls.inspect}"
  end

  test "the registry password reaches docker login on stdin, never in argv" do
    _out, status, _build, calls = run_script({})

    assert status.success?
    assert calls.any? { |c| c.start_with?("login ghcr.io -u chaim354 --password-stdin") }, calls.inspect
    refute_includes calls.join("\n"), STUB_TOKEN, "the token must not appear in any docker argv"
  end

  test "SYNC_PUSH_LATEST other than 0 or 1 is refused rather than read as yes" do
    # The dangerous direction is moving `:latest` by accident; `SYNC_PUSH_LATEST=no` must not do it.
    out, status, _build, calls = run_script("SYNC_PUSH_LATEST" => "no")

    assert_equal 2, status.exitstatus, out
    assert_includes out, "SYNC_PUSH_LATEST must be 0 or 1, not 'no'"
    assert_empty calls, "a refused build must not even log in: #{calls.inspect}"
  end

  private

  STUB_TOKEN = "stub-not-a-token"

  # Runs the script from the repo root (it calls bin/secret by relative path) with `docker` shimmed to
  # record its argv and consume login's stdin. bin/secret returns an exported value before asking
  # 1Password, so no `op` call is made. Returns [combined output, status, the `buildx build` argv line
  # or nil, every docker argv line].
  def run_script(env)
    Dir.mktmpdir("build-and-push") do |dir|
      log  = File.join(dir, "docker.log")
      shim = File.join(dir, "docker")
      File.write(shim, <<~SH)
        #!/bin/sh
        # Record every invocation, one per line. `login` reads its password from stdin, so drain it
        # rather than let the script's `echo` die of SIGPIPE under pipefail.
        if [ "$1" = login ]; then cat >/dev/null; fi
        printf '%s\\n' "$*" >> "#{log}"
        exit 0
      SH
      FileUtils.chmod(0o755, shim)
      full_env = {
        "PATH" => "#{dir}:#{ENV['PATH']}",
        "KAMAL_REGISTRY_PASSWORD" => STUB_TOKEN,
        "SYNC_IMPL" => nil, "SYNC_PUSH_LATEST" => nil
      }.merge(env)
      out, status = Open3.capture2e(full_env, SCRIPT.to_s, chdir: ROOT.to_s)
      calls = File.exist?(log) ? File.readlines(log, chomp: true) : []
      [ out, status, calls.grep(/\Abuildx build /).first, calls ]
    end
  end

  def tags_of(build_line)
    build_line.scan(/(?:^| )-t (\S+)/).flatten
  end
end
