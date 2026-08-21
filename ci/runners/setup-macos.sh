#!/usr/bin/env bash
# Register a self-hosted Actions runner on this Mac against chaim354/tinkerex-sync.
#
# SELF-HOSTED RUNNERS REGISTER PER REPOSITORY, NOT PER ORG. A runner registered against
# chaim354/tinkerex is invisible here, so this box needs a SECOND runner service even though it
# already runs one. Until that exists, .github/workflows/ci.yml queues against a runner family
# that does not exist and is auto-cancelled after 24h with NOTHING RED ANYWHERE -- the five-week
# outage shape the tinkerex repo's own ci/preflight.sh header describes.
#
# REPO_URL IS HARDCODED ON PURPOSE, mirroring tinkerex's copy of this script. Taking the repo as
# an argument would make registering the wrong box against the wrong repo a one-character typo,
# which is worse than two small near-duplicate scripts.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT INSTALL: Rust, mingw-w64, rclone. tinkerex's version
# installs all three because its runner cross-compiles the Windows client and drives rclone
# conformance. This repo is a Rails engine -- its whole suite is `bundle exec rake test` against
# test/dummy -- so those would be several GB of toolchain that no job here ever invokes.
#
#   gh api -X POST repos/chaim354/tinkerex-sync/actions/runners/registration-token --jq .token
#   ./ci/runners/setup-macos.sh <THAT_TOKEN>
#
# The token is single-use and expires in an hour; it is NOT a PAT and grants only registration.
set -euo pipefail

TOKEN="${1:?Usage: setup-macos.sh <REGISTRATION_TOKEN>}"
REPO_URL="https://github.com/chaim354/tinkerex-sync"
# Distinct from ~/actions-runner-tinkerex so the two services cannot share a work directory.
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-tinkerex-sync}"
LABELS="self-hosted,macos,maker-mac"

command -v jq >/dev/null 2>&1 || { echo "jq required: brew install jq"; exit 1; }

# Ruby is NOT installed here. The box already carries a mise ruby matching .ruby-version, which is
# exactly why .github/workflows/ci.yml uses a bare `bundle install` and no ruby/setup-ruby -- that
# action assumes a hosted /Users/runner layout this machine does not have.
ruby -v >/dev/null 2>&1 || { echo "No ruby on PATH -- the workflow expects the box's mise ruby"; exit 1; }

ARCH="$( [ "$(uname -m)" = "arm64" ] && echo arm64 || echo x64 )"
echo "==> Downloading the latest GitHub Actions runner (osx-$ARCH)"
mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"
VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')"
TARBALL="actions-runner-osx-${ARCH}-${VERSION}.tar.gz"
[ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" \
  "https://github.com/actions/runner/releases/download/v${VERSION}/${TARBALL}"
tar xzf "$TARBALL"

echo "==> Configuring against $REPO_URL (labels: $LABELS)"
# The launchd service name is derived as actions.runner.<owner>-<repo>.<runner-name>, so this does
# not collide with actions.runner.chaim354-tinkerex.<same-name> already on this box.
./config.sh --unattended --replace \
  --url "$REPO_URL" --token "$TOKEN" \
  --name "$(hostname -s)-maker-mac" --labels "$LABELS"

echo "==> Installing + starting the runner service (launchd, user-level -- no sudo)"
./svc.sh install
./svc.sh start

echo "==> Verify:  gh api repos/chaim354/tinkerex-sync/actions/runners --jq '.runners[].name'"
