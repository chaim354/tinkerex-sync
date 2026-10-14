# frozen_string_literal: true

source "https://rubygems.org"

# ONLY THE CONFORMANCE TOOLING IS RUBY NOW. Phase 6 of docs/superpowers/plans/2026-09-30-rust-rewrite.md
# deleted the Rails engine and its host; the server is the Rust binary under crates/, built with
# cargo. What stays Ruby stays so on purpose: the corpus verifier (test/conformance_test.rb) and
# recorder (bin/conformance-record) grade that binary from OUTSIDE its own language, because a
# grader written by the same hands as the server would share its assumptions (conformance/README.md,
# "Why this corpus exists"). These gems are all the two need, plus bin/build-and-push's own test.
#
# NO `psych`: YAML is Ruby's default psych gem, which every Ruby this repo runs carries and which
# this bundle has always used (it was never in the lock). Naming it would trade that for a gem build
# that needs libyaml headers, for no gain.

gem "rake"     # the `test` task (Rakefile)
gem "minitest" # plain Minitest -- the files under test/ have needed no Rails since Phase 6

# conformance/schema.json validation (test/conformance_test.rb) -- MIT, and its own runtime deps
# are three small MIT gems (hana, regexp_parser, simpleidn) plus bigdecimal; checked directly
# against each fetched .gem's own gemspec, not assumed. The schema declares draft 2020-12, which
# this is the one maintained Ruby gem supporting.
gem "json_schemer"
