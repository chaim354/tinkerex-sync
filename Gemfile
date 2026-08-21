# frozen_string_literal: true

source "https://rubygems.org"

# The engine's own runtime deps (rails, aws-sdk-s3) come from the gemspec.
gemspec

# Only what test/dummy needs to BE a Rails app -- the engine itself requires none of these.
gem "sqlite3"        # test/dummy/config/database.yml
gem "debug", require: false, group: %i[development test]
