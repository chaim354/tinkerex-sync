# frozen_string_literal: true

require "test_helper"
require_relative "../conformance/runner"

# THE MATCHER IS THE WHOLE CORPUS'S TEETH. A recorded expectation is only worth what the matcher
# refuses, so these tests are mostly about what must NOT match -- an over-permissive matcher would
# record a corpus that passes against a server doing the wrong thing, which is the FakeS3 shape
# (CLAUDE.md §14e) one level up.
class ConformanceRunnerTest < ActiveSupport::TestCase
  M = Conformance::Matcher

  test "a literal must match exactly" do
    assert M.new.match!({ "a" => 1 }, { "a" => 1 })
    assert_raises(Conformance::Mismatch) { M.new.match!({ "a" => 1 }, { "a" => 2 }) }
  end

  test "an extra key in the actual body is a mismatch, not a pass" do
    # THE DIRECTION THAT MATTERS. A subset match would let a server add a field nobody vetted --
    # and for a wire contract, a new field IS a contract change.
    assert_raises(Conformance::Mismatch) { M.new.match!({ "a" => 1 }, { "a" => 1, "b" => 2 }) }
  end

  test "a missing key is a mismatch" do
    assert_raises(Conformance::Mismatch) { M.new.match!({ "a" => 1, "b" => 2 }, { "a" => 1 }) }
  end

  test "$capture binds a value and matches anything" do
    m = M.new
    m.match!({ "id" => { "$capture" => "node" } }, { "id" => "abc" })
    assert_equal "abc", m.bindings["node"]
  end

  test "$ref must equal what was captured" do
    m = M.new
    m.match!({ "id" => { "$capture" => "node" } }, { "id" => "abc" })
    assert m.match!({ "id" => { "$ref" => "node" } }, { "id" => "abc" })
    assert_raises(Conformance::Mismatch) { m.match!({ "id" => { "$ref" => "node" } }, { "id" => "xyz" }) }
  end

  test "$ref to an unbound name is an error, not a silent pass" do
    assert_raises(Conformance::Mismatch) { M.new.match!({ "id" => { "$ref" => "never" } }, { "id" => "abc" }) }
  end

  test "$type checks the type and nothing else" do
    assert M.new.match!({ "seq" => { "$type" => "integer" } }, { "seq" => 7 })
    assert_raises(Conformance::Mismatch) { M.new.match!({ "seq" => { "$type" => "integer" } }, { "seq" => "7" }) }
  end

  test "$absent requires the key to be missing" do
    assert M.new.match!({ "gone" => { "$absent" => true } }, {})
    assert_raises(Conformance::Mismatch) { M.new.match!({ "gone" => { "$absent" => true } }, { "gone" => nil }) }
  end

  test "a null value is not the same as an absent key" do
    # These are different answers on the wire and the corpus must be able to tell them apart --
    # chunk_remote's own restore-to-root case turns on parent_node_id being NULL rather than gone.
    assert M.new.match!({ "parent_node_id" => nil }, { "parent_node_id" => nil })
    assert_raises(Conformance::Mismatch) { M.new.match!({ "parent_node_id" => nil }, {}) }
  end

  test "interpolation substitutes bound values into strings" do
    m = M.new
    m.match!({ "id" => { "$capture" => "node" } }, { "id" => "abc" })
    assert_equal "/v1/nodes/abc/move", m.interpolate("/v1/nodes/{{node}}/move")
  end

  test "interpolating an unbound name raises rather than emitting the literal braces" do
    assert_raises(Conformance::Mismatch) { M.new.interpolate("/v1/nodes/{{nope}}") }
  end
end
