# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# bin/build-and-push's TAGGING is what the cutover leans on (docs/superpowers/plans/
# 2026-10-07-rust-cutover.md §0.3.3): `:latest` is what the maker app's `sync` accessory pulls on its
# next reboot, so a build that moves it ARMS a cutover, and a revision tag without the implementation
# in it lets a Ruby build and a Rust build of one commit overwrite each other. These drive the REAL
# script with a recording `docker` shim on PATH and read back the one `buildx build` call it makes --
# the wire, not a re-derivation of the script's arithmetic.
class BuildAndPushTest < ActiveSupport::TestCase
  ROOT   = Pathname.new(File.expand_path("..", __dir__))
  SCRIPT = ROOT.join("bin/build-and-push")
  REPO   = "ghcr.io/chaim354/tinkerex-sync"
  REVISION_TAG = /\A#{Regexp.escape(REPO)}:[0-9a-f]{40}(-dirty)?-(ruby|rust)\z/

  test "SYNC_PUSH_LATEST=0 pushes the implementation-suffixed revision tag and leaves :latest alone" do
    out, status, build, calls = run_script("SYNC_IMPL" => "rust", "SYNC_PUSH_LATEST" => "0")

    assert status.success?, out
    refute_nil build, "expected one `docker buildx build`, got: #{calls.inspect}"
    assert_includes build, "-f Dockerfile.rust"
    assert_includes build, "--label org.opencontainers.image.description=tinkerex-sync (rust)"
    assert_includes build, "--push"

    tags = tags_of(build)
    assert_equal 1, tags.size, "exactly one tag, got #{tags.inspect}"
    assert_match REVISION_TAG, tags.first
    assert tags.first.end_with?("-rust"), tags.first
    assert_match(/left #{Regexp.escape(REPO)}:latest untouched/, out)
    assert_match(/imagetools create -t #{Regexp.escape(REPO)}:latest #{Regexp.escape(tags.first)}/, out,
                 "the promote command is printed, naming the tag just pushed")
  end

  test "the default build still moves :latest beside a :<sha>-ruby tag, with SYNC_IMPL unset" do
    # The bare invocation is the one that broke: `set -u` plus a bare `$SYNC_IMPL` in the label exited
    # "unbound variable" after docker login. SYNC_IMPL is explicitly UNSET here, not "ruby".
    out, status, build, calls = run_script({})

    assert status.success?, out
    refute_nil build, "expected one `docker buildx build`, got: #{calls.inspect}"
    assert_includes build, "-f Dockerfile "
    assert_includes build, "--label org.opencontainers.image.description=tinkerex-sync (ruby)"

    tags = tags_of(build)
    assert_equal 2, tags.size, tags.inspect
    assert_includes tags, "#{REPO}:latest"
    revision = (tags - [ "#{REPO}:latest" ]).first
    assert_match REVISION_TAG, revision
    assert revision.end_with?("-ruby"), revision
    assert_match(/pushed #{Regexp.escape(REPO)}:latest -> #{Regexp.escape(revision)}/, out)
  end

  test "the registry password reaches docker login on stdin, never in argv" do
    _out, status, _build, calls = run_script("SYNC_IMPL" => "ruby")

    assert status.success?
    assert calls.any? { |c| c.start_with?("login ghcr.io -u chaim354 --password-stdin") }, calls.inspect
    refute_includes calls.join("\n"), STUB_TOKEN, "the token must not appear in any docker argv"
  end

  test "an unknown SYNC_IMPL is refused by name before docker is touched at all" do
    out, status, _build, calls = run_script("SYNC_IMPL" => "python")

    assert_equal 2, status.exitstatus, out
    assert_includes out, "python"
    assert_empty calls, "a refused build must not even log in: #{calls.inspect}"
  end

  test "SYNC_PUSH_LATEST other than 0 or 1 is refused rather than read as yes" do
    # The dangerous direction is moving `:latest` by accident; `SYNC_PUSH_LATEST=no` must not do it.
    out, status, _build, calls = run_script("SYNC_IMPL" => "rust", "SYNC_PUSH_LATEST" => "no")

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
