# frozen_string_literal: true

# THE WHOLE TEST HARNESS SINCE PHASE 6 (docs/superpowers/plans/2026-09-30-rust-rewrite.md §9)
# deleted the Ruby engine and its host. What is left under test/ is tooling: the conformance
# verifier (conformance_test.rb), the matcher it shares with bin/conformance-record
# (conformance_runner_test.rb), and bin/build-and-push's tagging (build_and_push_test.rb). There is
# no app to boot, so this is plain Minitest -- no Rails. The server those tools grade is the Rust
# binary, reached over HTTP by bin/conformance; its own suite is `cargo test`.
require "minitest/autorun"

module Minitest
  class Test
    # `test "name" do ... end` -- the declaration these files were written in (ActiveSupport's),
    # kept so their method names did not change when Rails left. That is not cosmetic for
    # conformance_test.rb, which runs its tests in ALPHABETICAL method-name order on purpose (see
    # i_suck_and_my_tests_are_order_dependent! there). The name is `test_` plus the words joined by
    # underscores, as ActiveSupport::Testing::Declarative spelled it, and a duplicate raises rather
    # than silently replacing the earlier test.
    def self.test(name, &block)
      method_name = :"test_#{name.gsub(/\s+/, '_')}"
      raise "#{method_name} is already defined in #{self}" if method_defined?(method_name)

      define_method(method_name, &block)
    end
  end
end
