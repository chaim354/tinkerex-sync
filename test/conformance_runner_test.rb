# frozen_string_literal: true

require "test_helper"
require_relative "../conformance/runner"

# THE MATCHER IS THE WHOLE CORPUS'S TEETH. A recorded expectation is only worth what the matcher
# refuses, so these tests are mostly about what must NOT match -- an over-permissive matcher would
# record a corpus that passes against a server doing the wrong thing, which is the FakeS3 shape
# (CLAUDE.md §14e) one level up.
class ConformanceRunnerTest < Minitest::Test
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

  # #bind_captures! is what bin/conformance-record's --force path calls, in place of #match!,
  # before it overwrites an already-recorded step's expectation -- see its own comment in
  # conformance/runner.rb for the full argument. These tests pin the CONTRACT that makes the fix
  # correct, independent of the live-server reproduction (02-commit.yml, forced against a real
  # host) that found the bug in the first place: no server is needed to prove this method binds
  # what #match! would have bound, and never raises doing it.
  test "bind_captures! binds a $capture from the actual response, just like match! would" do
    m = M.new
    m.bind_captures!({ "id" => { "$capture" => "node" } }, { "id" => "abc" })
    assert_equal "abc", m.bindings["node"]
  end

  test "bind_captures! is what makes a --force'd capture chain survive -- 02-commit.yml's own shape" do
    # This is exactly 02-commit.yml's step 1/step 2 pair: a presigned PUT URL nested inside a
    # hash keyed by chunk hash, captured, then interpolated into the next step's request path.
    # Before this method existed, --force discarded step 1's old expectation without ever
    # bothering to bind it, and the next line raised Conformance::Mismatch -- reproduced for real
    # by running `bin/conformance-record --force conformance/scenarios/02-commit.yml` against a
    # live server, before this fix existed.
    m = M.new
    old_expectation = { "put_urls" => { "cdb31e4c" => { "$capture" => "drawing_put_url" } } }
    live_response    = { "put_urls" => { "cdb31e4c" => "https://storage.example/upload?sig=xyz" } }
    m.bind_captures!(old_expectation, live_response)
    assert_equal "https://storage.example/upload?sig=xyz", m.interpolate("{{drawing_put_url}}")
  end

  test "bind_captures! recurses through nested hashes and arrays to find every $capture" do
    m = M.new
    m.bind_captures!(
      { "items" => [{ "id" => { "$capture" => "first" } }, { "id" => { "$capture" => "second" } }] },
      { "items" => [{ "id" => "one" }, { "id" => "two" }] }
    )
    assert_equal "one", m.bindings["first"]
    assert_equal "two", m.bindings["second"]
  end

  test "bind_captures! never raises -- unlike match!, a shape it can no longer walk just stops" do
    m = M.new
    # The key the capture needs is gone entirely -- --force exists for exactly this: a response
    # that no longer looks like the recording it is replacing. match! would raise here; this must
    # not.
    assert_nil m.bind_captures!({ "id" => { "$capture" => "node" } }, {})
    assert_nil m.bindings["node"]
    # A Hash in the old expectation, but the live response is not a Hash at all any more.
    assert_nil m.bind_captures!({ "id" => 1 }, "not a hash any more")
    # Same, for an Array.
    assert_nil m.bind_captures!([{ "$capture" => "x" }], "not an array any more")
    assert_nil m.bindings["x"]
  end

  test "bind_captures! treats $ref as inert -- it verifies elsewhere, it does not bind" do
    m = M.new
    # No earlier step bound "never" at all. Run through match!'s own $ref check this would raise
    # "no earlier $capture bound this name" -- exactly the failure --force exists to route around,
    # since an old $ref is a validation against a PRIOR capture, never a new binding of its own.
    assert_nil m.bind_captures!({ "id" => { "$ref" => "never" } }, { "id" => "anything" })
    assert_empty m.bindings
  end

  test "bind_captures! does not clear an earlier binding just because this response lacks the field" do
    m = M.new
    m.bind_captures!({ "id" => { "$capture" => "node" } }, { "id" => "abc" })
    m.bind_captures!({ "id" => { "$capture" => "node" } }, {})
    assert_equal "abc", m.bindings["node"]
  end
end
