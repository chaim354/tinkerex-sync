# frozen_string_literal: true

source "https://rubygems.org"

# The engine's own runtime deps (rails, aws-sdk-s3) come from the gemspec.
gemspec

# Only what the two apps in this repo need to BE Rails apps -- the engine itself requires none of
# these, and none is a runtime dependency of the gem (see the gemspec).
gem "sqlite3"        # test/dummy and host/ both use it

# host/ IS MEANT TO BE RUN, and without a server gem `bin/rails server` exits with
# "Could not find a server gem" -- which no suite could ever have caught, because a test boots the
# app without ever serving HTTP. Found by starting it.
gem "puma"
gem "debug", require: false, group: %i[development test]
