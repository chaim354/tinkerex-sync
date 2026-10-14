# frozen_string_literal: true

# THE RUBY LEFT IN THIS REPOSITORY IS TOOLING (the Gemfile says why), and this is its one task.
# `bundle exec rake test` runs every test/**/*_test.rb: the matcher's own tests, bin/build-and-push's
# tagging, and the conformance verifier -- whose sixteen scenario tests SKIP unless SYNC_SERVER_URL
# names a running server. bin/conformance boots the binary, runs the verifier against it, and fails
# on any skip; the server's own suite is `cargo test`. The engine's suite and the host's
# (`rake test:host`) left with the Ruby in Phase 6.
require "bundler/setup"

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
  t.verbose = false
end

task default: :test
