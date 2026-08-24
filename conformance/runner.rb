# THE MATCHER IS THE CORPUS'S ONLY TEETH.
#
# A conformance scenario records what a REAL server answered for a given request; replaying it
# later is only as trustworthy as this file's willingness to say "no, that is not what was
# recorded." An over-permissive matcher is worse than no corpus at all -- it LOOKS like coverage
# while proving nothing, which is exactly the shape this repo's own history has already paid for
# once: FakeS3 decoded `copy_source` with CGI.unescape while the real adapter encoded with
# CGI.escape, exact inverses, and 79 of 80 tests stayed green over silent permanent data loss on
# any filename containing a space (CLAUDE.md §14e, the tinkerex monorepo). A fake and the code
# under test sharing one wrong assumption is invisible to both. The fix there is the fix here:
# assert the WIRE, exactly, never a round trip through a shared misunderstanding.
#
# SO: matching is EXACT, IN BOTH DIRECTIONS, by default. A key present in the actual response but
# not named in the expectation is a MISMATCH, not a pass -- for a wire contract, a field a server
# added that nobody vetted IS a contract change, and a matcher that shrugs at new fields would
# never catch a Rust rewrite that leaks an internal id or silently drops a deprecated one. The
# four special forms below ($capture / $ref / $type / $absent), plus a bare literal, are the ONLY
# ways a recorded expectation can say "this part is allowed to vary" -- five forms, deliberately,
# and no more without a strong argument (conformance/README.md is the normative spec a non-Ruby
# implementer reads instead of this file).
#
# USED BY BOTH THE RECORDER AND THE VERIFIER (later tasks), so the two cannot disagree about what
# "matches" means. Splitting this logic in two would let one drift permissive without the other
# noticing -- the exact FakeS3 shape, one level up.
#
# NOT AUTOLOADED. `conformance/` is not under app/ or lib/, and the gemspec's `spec.files` does
# not include it -- this is dev/test tooling for THIS repo, not something a host installing the
# gem should receive, so Zeitwerk never sees it and never should. Every caller `require_relative`s
# this file directly, the same way test/conformance_runner_test.rb does.
module Conformance
  # Raised for every way an actual value can fail to satisfy a recorded expectation: a wrong
  # value, an extra or missing key, an unbound $ref, an unbound {{interpolation}}. ONE class for
  # all of it, deliberately -- a corpus author or a non-Ruby port reading a failure should not
  # need a taxonomy of exception types to react to it, only the message, which always names the
  # JSON path that failed (see Matcher#fail! below). Splitting this into
  # MismatchValue/MismatchShape/MismatchRef etc. would just be a second small vocabulary sitting
  # beside the five-form one this file exists to keep small.
  class Mismatch < StandardError; end

  # Matches one recorded EXPECTED value (parsed from scenario YAML/JSON: hashes, arrays, strings,
  # numbers, booleans, nil, and the four special-form hashes) against one ACTUAL value (parsed
  # from a real HTTP response body, or replayed from a recording). One Matcher instance owns the
  # $capture/$ref bindings for a single scenario's run start to finish, so a node id captured in
  # step 2 can be referenced by $ref in step 5 -- bindings do NOT reset between #match! calls on
  # the same instance.
  class Matcher
    SPECIAL_FORMS = %w[$capture $ref $type $absent].freeze

    # $type's vocabulary deliberately matches JSON Schema's primitive type names rather than
    # inventing a Ruby-flavoured one (Integer/String/...) -- scenario files double as JSON
    # Schema-validated documents (conformance/schema.json), and a non-Ruby implementer's own JSON
    # library already has these names, not Ruby's.
    TYPE_CHECKS = {
      "string" => ->(v) { v.is_a?(String) },
      "integer" => ->(v) { v.is_a?(Integer) },
      # true and false are each the sole instance of their own class in Ruby (TrueClass/
      # FalseClass) with no shared boolean superclass, so `is_a?` on either is the honest way to
      # ask "is this a boolean" -- there is no `Boolean` to check against.
      "boolean" => ->(v) { v.is_a?(TrueClass) || v.is_a?(FalseClass) },
      "array" => ->(v) { v.is_a?(Array) },
      "object" => ->(v) { v.is_a?(Hash) },
      # NOT the same question $absent asks. $type: null demands the key be PRESENT with an
      # explicit JSON null; a MISSING key fails this check too, because NOT_PRESENT (below) is
      # not nil -- the same "null and absent are different answers on the wire" rule the whole
      # matcher exists to keep, applied here.
      "null" => ->(v) { v.nil? }
    }.freeze

    # A private sentinel standing in for "this key does not exist in the actual hash at all" --
    # a bare object with no overridden equality, so it is never equal to anything but itself.
    # That is what lets a MISSING key and a PRESENT-but-wrong value share one comparison path
    # (#match_hash! below, then #match_literal!) instead of two independently written checks that
    # could silently disagree about which one fires first. It never leaves this file: no test, no
    # caller, ever sees a MissingKey instance directly -- they only ever see the Mismatch it
    # causes.
    class MissingKey
      def inspect = "(missing)"
    end
    NOT_PRESENT = MissingKey.new.freeze

    attr_reader :bindings

    def initialize
      @bindings = {}
    end

    # The entry point. `path` is the JSON-path label a Mismatch message is built from -- the code
    # that drives a real HTTP call (a later task) calls this once per response with path: "body"
    # (or "status", "headers"), so a failure reads `body.changes[0].node_id: ...` rather than the
    # bare `$.changes[0].node_id` this file would invent by itself if left to the default.
    #
    # Returns true on a full match; raises Mismatch, naming the path, at the FIRST disagreement --
    # there is no "collect every mismatch and report them all" mode. A Hash whose shape itself
    # disagrees two levels up (a missing key) has no principled value left underneath to keep
    # comparing, so stopping at the first failure is not a shortcut -- it is the only answer that
    # is not misleading about what was actually checked.
    def match!(expected, actual, path = "$")
      if special_form?(expected)
        match_special_form!(expected, actual, path)
      elsif expected.is_a?(Hash)
        match_hash!(expected, actual, path)
      elsif expected.is_a?(Array)
        match_array!(expected, actual, path)
      else
        match_literal!(expected, actual, path)
      end
    end

    # Substitutes {{name}} in a request path/query/body value with whatever #match! most recently
    # bound to NAME via $capture. Raises on an unbound name RATHER THAN emitting the literal
    # `{{name}}` text -- a request built from a half-substituted template goes to a nonsense path,
    # and the 404 it produces points at the wrong place entirely: the string "{{node}}" sitting in
    # a URL reads as a typo in the SERVER, not as a scenario referencing a capture that was never
    # made. Failing here, at the template, keeps the error where the mistake actually is.
    def interpolate(template)
      template.gsub(/\{\{(\w+)\}\}/) do
        name = Regexp.last_match(1)
        raise Mismatch, "{{#{name}}}: no earlier $capture bound this name" unless @bindings.key?(name)

        @bindings[name].to_s
      end
    end

    # Best-effort capture binding for a step about to be overwritten by --force. #match! is the
    # ONLY thing that ever binds a $capture (see its own comment above); bin/conformance-record's
    # --force path used to overwrite a step's recorded expectation WITHOUT ever calling it, so a
    # later step's {{name}} interpolation -- built from a request a human wrote once and never
    # revisits -- found nothing bound. Reproduced for real: forcing 02-commit.yml crashed on step
    # 2's `PUT {{drawing_put_url}}` with "no earlier $capture bound this name", because step 1's
    # recorded `put_urls.<hash>: {"$capture": drawing_put_url}` was discarded unread.
    #
    # UNLIKE #match!, THIS NEVER RAISES. --force exists precisely because the live response may no
    # longer look like the recording it is about to replace, so the shape checks that make #match!
    # a trustworthy gate (missing key, wrong type, an extra key) would turn this into a second
    # --force refusal by another name -- exactly what --force is for skipping. A shape disagreement
    # between the OLD `expected` and the NEW `actual` (a vanished key, a Hash where an Array now
    # sits, an array that changed length) simply stops that branch's walk: nothing is bound from
    # underneath it, and nothing is raised. A capture that genuinely cannot be recovered this way
    # still surfaces -- just later, and more legibly, as the next step's own {{name}} interpolation
    # raising the same Mismatch it always has, naming the request that needed it, rather than this
    # method raising about a response shape --force was explicitly told to accept.
    #
    # $ref IS DELIBERATELY INERT HERE, NOT REVALIDATED. A $ref checks a value against an earlier
    # capture; it never introduces a binding of its own, so skipping it costs nothing. Running it
    # through the same equality check #match_special_form! uses -- and raising on a disagreement --
    # would smuggle validation back in through a method whose whole job is to not validate. $type
    # and $absent are inert for the identical reason: neither binds anything even inside #match!.
    #
    # CALLED ONCE PER STEP, against that step's OLD expectation and the NEW live response, BEFORE
    # the expectation is overwritten -- bin/conformance-record's record_scenario is the only
    # caller. Sequencing is what makes this work: a later step's request is only interpolated
    # after this has run for every step before it, which is what lets a bound {{drawing_put_url}}
    # survive a forced re-record.
    def bind_captures!(expected, actual)
      if special_form?(expected)
        operator, argument = expected.first
        @bindings[argument] = actual if operator == "$capture" && !actual.equal?(NOT_PRESENT)
      elsif expected.is_a?(Hash) && actual.is_a?(Hash)
        expected.each do |key, expected_value|
          actual_value = actual.key?(key) ? actual[key] : NOT_PRESENT
          bind_captures!(expected_value, actual_value)
        end
      elsif expected.is_a?(Array) && actual.is_a?(Array)
        expected.each_with_index { |expected_value, i| bind_captures!(expected_value, actual[i]) if i < actual.size }
      end
      nil
    end

    private

    # A hash counts as a special form ONLY when it has exactly one key and that key is one of the
    # four recognised operators -- a hash with more than one key, even if one of them happens to
    # start with "$", is an ordinary object to match key-by-key. This is what tells a bare
    # `{ "$capture" => "node" }` apart from `{ "id" => { "$capture" => "node" } }`'s INNER hash
    # with no second code path: #match! dispatches on the value at every level of recursion, and
    # only the inner one satisfies this check.
    def special_form?(value)
      value.is_a?(Hash) && value.size == 1 && SPECIAL_FORMS.include?(value.keys.first)
    end

    def match_special_form!(expected, actual, path)
      operator, argument = expected.first
      case operator
      when "$capture"
        # A guard, not a fallout of the generic equality check below: there is no "expected
        # value" for a capture to compare against, so a missing key must be refused explicitly
        # right here rather than left to surface later. Left unguarded, capturing a key the
        # response never sent would silently bind NOT_PRESENT under `argument` and defer a
        # confusing failure to whichever $ref reads it back, far from the actual cause.
        raise Mismatch, "#{path}: expected a value to capture, but the key was missing" if actual.equal?(NOT_PRESENT)

        @bindings[argument] = actual
        true
      when "$ref"
        fail!(path, "$ref to #{argument.inspect}, which no earlier $capture bound") unless @bindings.key?(argument)

        bound = @bindings[argument]
        unless bound == actual
          fail!(path, "expected #{bound.inspect} (bound to #{argument.inspect}), got #{describe(actual)}")
        end
        true
      when "$type"
        check = TYPE_CHECKS.fetch(argument) { fail!(path, "unknown $type #{argument.inspect}") }
        fail!(path, "expected $type #{argument.inspect}, got #{describe(actual)}") unless check.call(actual)
        true
      when "$absent"
        # The one form that asks about PRESENCE rather than VALUE, which is why it alone compares
        # `actual` against the sentinel instead of against something recorded earlier. A present
        # key mapped to an explicit `nil` still fails this -- "null and absent are different
        # answers on the wire," applied at its origin.
        unless actual.equal?(NOT_PRESENT)
          fail!(path, "expected the key to be absent, but it was present (value: #{actual.inspect})")
        end
        true
      end
    end

    def match_hash!(expected, actual, path)
      fail!(path, "expected an object, got #{describe(actual)}") unless actual.is_a?(Hash)

      expected.each do |key, expected_value|
        actual_value = actual.key?(key) ? actual[key] : NOT_PRESENT
        match!(expected_value, actual_value, "#{path}.#{key}")
      end

      # THE DIRECTION THAT MATTERS MOST. Everything above checks that every key the scenario
      # NAMED is right; this checks that the response did not send anything MORE than that. Skip
      # this and the matcher degrades to a subset check -- precisely the mutation Step 6 exists to
      # catch, and precisely the shape that would let a server bolt an unreviewed field onto a
      # wire contract with the corpus none the wiser.
      extra = actual.keys - expected.keys
      fail!(path, "actual has key(s) not in expected: #{extra.join(', ')}") unless extra.empty?

      true
    end

    def match_array!(expected, actual, path)
      fail!(path, "expected an array, got #{describe(actual)}") unless actual.is_a?(Array)
      fail!(path, "expected #{expected.size} element(s), got #{actual.size}") unless expected.size == actual.size

      expected.each_with_index { |expected_value, i| match!(expected_value, actual[i], "#{path}[#{i}]") }
      true
    end

    def match_literal!(expected, actual, path)
      fail!(path, "expected #{expected.inspect}, got #{describe(actual)}") unless expected == actual
      true
    end

    # NOT_PRESENT prints as "(missing)" in a failure message instead of a MissingKey instance's
    # default #<Conformance::Matcher::MissingKey:0x...> -- the entire point of naming a path in
    # every Mismatch is to leave a human something legible to read, and a raw object id is not
    # that.
    def describe(value)
      value.equal?(NOT_PRESENT) ? "(missing)" : value.inspect
    end

    def fail!(path, detail)
      raise Mismatch, "#{path}: #{detail}"
    end
  end
end
