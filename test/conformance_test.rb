# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require "yaml"
require "pathname"
require "set"
require "json_schemer"

require_relative "../conformance/runner"

# THE VERIFIER. An ordinary Minitest file, so `bundle exec rake test` picks it up like every other
# suite under test/ -- no separate binstub, no separate mechanism to remember to invoke. Each
# scenario under conformance/scenarios/*.yml becomes one test: validate it against
# conformance/schema.json, send every step's request to a REAL server in order, and match every
# recorded expectation via Conformance::Matcher#match! (conformance/runner.rb) -- the same class
# bin/conformance-record uses to WRITE those expectations down, so the two cannot disagree about
# what "matches" means (runner.rb's own header comment is the argument for that sharing; this file
# is the second half of the reason it exists).
#
# SKIPS CLEANLY WITH NO SERVER, ON PURPOSE. This corpus's whole point is exercising a REAL, RUNNING
# host -- "expectations written by the same mind that wrote the implementation agree with the
# implementation, including where the implementation is wrong" (runner.rb, restating the FakeS3
# lesson) -- so there is no in-process fake standing in when one is not configured; the server
# under test is the Rust binary, and only a running one can answer. `rake test` must still exit
# green with no server configured (nobody without one should have their run broken by this file),
# so every per-scenario test below skips on ENV["SYNC_SERVER_URL"] rather than failing or erroring.
#
# THAT SKIP IS INVISIBLE TO ANYTHING INSIDE THIS SUITE. A skipped test and an executed, passing
# test both report "not red," and nothing in Minitest lets one test assert about another test's own
# skip -- so the guarantee that this file actually ran for real, rather than quietly skipping,
# belongs to the CALLER, not to this file. bin/conformance -- what .github/workflows/ci.yml's
# conformance job runs -- boots a fresh server, sets both env vars below, AND parses the run's own
# summary line for a nonzero skip count or zero runs, failing if it finds either. Running this
# suite by hand with no server is the one case where a skip is not just expected but correct.
#
# THE ONE TEST THAT NEVER SKIPS: "the corpus has at least one scenario file". Every test below it is
# GENERATED from Dir.glob's result at class-definition time. If that glob ever silently returned
# nothing -- a typo'd path, conformance/scenarios/ renamed out from under this file -- there would
# be nothing to generate, nothing to skip, and nothing to run: `rake test` would report a clean 0
# runs for this file's would-be coverage and look exactly like success. This one test has no server
# dependency, always runs, and turns that failure mode into a loud, ordinary red.
class ConformanceTest < Minitest::Test
  SCENARIOS_DIR = File.expand_path("../conformance/scenarios", __dir__)
  SCHEMA_PATH   = File.expand_path("../conformance/schema.json", __dir__)

  # Parsed once at class-definition time, not once per scenario -- schema.json cannot change
  # mid-run, so re-parsing it per scenario would be pure waste.
  SCHEMA = JSONSchemer.schema(Pathname.new(SCHEMA_PATH))

  # THE ROUTE TABLE, AS THE BINARY PRINTS IT. `tinkerex-sync routes` lists every route the server
  # serves, one `METHOD /path` line each (path parameters spelled `:name`, as the Ruby drawer
  # spelled them), and conformance/routes.txt is that output checked in. The Rust test
  # crates/tinkerex-sync/tests/routes.rs fails the moment the two differ, so the file cannot drift
  # from the binary, and the binary cannot gain a route this coverage check never hears about. It
  # replaced Sync.draw_v1_routes, which this test drew into a throwaway RouteSet until Phase 6 of
  # docs/superpowers/plans/2026-09-30-rust-rewrite.md deleted the Ruby. Read once, at class-
  # definition time, the same way SCHEMA is; a MISSING file reads as no routes at all, which the
  # coverage test refuses by name -- rather than a load error taking every scenario test down too.
  ROUTES_PATH = File.expand_path("../conformance/routes.txt", __dir__)
  ROUTE_LINES = (File.exist?(ROUTES_PATH) ? File.readlines(ROUTES_PATH, chomp: true) : []).freeze
  ROUTE_LINE_RE = %r{\A(GET|POST|PUT|DELETE) (/\S*)\z}

  REQUEST_CLASS = {
    "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post, "PUT" => Net::HTTP::Put, "DELETE" => Net::HTTP::Delete
  }.freeze

  SCENARIO_PATHS = Dir.glob(File.join(SCENARIOS_DIR, "*.yml")).sort.freeze

  # ROUTES THIS CORPUS DELIBERATELY DOES NOT EXERCISE, EACH WITH A REASON -- keyed exactly as
  # conformance/routes.txt spells the route. Checked for staleness by the coverage test itself (a
  # key here that the route list no longer names is a bug in THIS list, not a passing exception),
  # so a route rename can't leave a stale excuse sitting here unnoticed.
  #
  # TWO ENTRIES, BOTH OUTSIDE THE SYNC WIRE, AND NEITHER A PLACEHOLDER LEFT FOR LATER: every one of
  # the 29 /v1 routes the binary serves is exercised by a real scenario step somewhere in
  # conformance/scenarios/*.yml, including the ones that looked likeliest to need an exception
  # going in -- POST /v1/share_links's anonymous redeem counterpart needs no second real device or
  # out-of-band credential (a second/third DEVICE is just another self-service POST /v1/devices
  # call against the SAME user, which this corpus already relies on for N-way conflicts), neither
  # presigned chunk-blob verb needs real object storage (STORAGE_BACKEND=local's blob tier is real
  # HTTP PUT/GET against THIS server, not a mock), and POST /v1/admin/libraries needs no live
  # secrets vault either -- SYNC_ADMIN_TOKEN is a fixed test fixture the booted server and
  # 11-admin.yml both agree on (see that file's own description). Until Phase 6 this list was
  # empty because the Ruby drawer it was checked against held only the 26 engine routes; the
  # binary's list also carries its readiness probe and its cable endpoint, and those two are here.
  COVERAGE_EXCEPTIONS = {
    "GET /up" => "the readiness probe, not the sync wire: it reads the users table and answers " \
                 "text/plain `ok`, and bin/conformance waits on it before the first scenario runs, " \
                 "so a server that cannot answer it never reaches this corpus at all",
    "GET /cable" => "a WebSocket upgrade, and this corpus's format is one HTTP request and one " \
                    "response per step -- it cannot hold a subscription open; " \
                    "crates/tinkerex-sync/tests/cable.rs drives it with the desktop client's own frames"
  }.freeze

  # MINITEST RANDOMIZES TEST-METHOD EXECUTION ORDER BY DEFAULT, AND THAT IS WRONG HERE -- not a
  # style preference, a correctness bug this file shipped with. Every scenario file below runs
  # against ONE SHARED, CONTINUOUSLY-MUTATED USER (one SYNC_DEVICE_TOKEN for the whole process),
  # so the corpus is not a set of independent tests -- it is one long, ordered session split across
  # files for readability, and later files ALREADY lean on that: 03-changes.yml's own description
  # says "this user already has history from 02-commit.yml", and 05-trash.yml's first three steps
  # restore tombstones that only exist because 04-nodes.yml's last step put them there. Even
  # 01-enrolment.yml's literal `head_seq: 0` depends on running FIRST -- true by accident until a
  # second scenario file existed to run before it. Proven by running this suite repeatedly: a
  # `--seed` that happened to schedule 05-trash.yml before 04-nodes.yml turned "restore 04-nodes
  # .yml's leftover Docs tombstone" into a 404 (nothing had tombstoned it yet), on a corpus where
  # every file was individually correct.
  #
  # `def self.test_order = :alpha` -- what an earlier version of this comment block sat above --
  # is a NO-OP on the minitest actually installed here (6.0.6): that gem renamed the override
  # point from Minitest 5's `test_order` to `run_order` (lib/minitest/test.rb, both
  # `Test.runnable_methods` and `Runnable.run_order`'s own default use the new name), so a class
  # defining the old one just adds an unused method while `run_order` keeps returning its base
  # `:random`. Silent, not an error: `ConformanceTest.test_order` still answered `:alpha` when
  # asked directly, which is exactly why this needs a comment and not just a diff. Found by running
  # the suite --verbose and reading the actual execution order, not by reading minitest's CHANGELOG.
  # `i_suck_and_my_tests_are_order_dependent!` is minitest's own public, documented convenience for
  # this (`Minitest::Test.i_suck_and_my_tests_are_order_dependent!`) -- used instead of `def
  # self.run_order = :alpha` directly because it is the stable public API (a method rename between
  # major versions already bit this file once) and because its deliberately self-deprecating name
  # is itself the warning: this suite is ORDER-DEPENDENT ON PURPOSE, not a suite that forgot to
  # isolate its tests. `:alpha` sorts test METHOD NAMES, which each embed the scenario's own
  # zero-padded filename (`test_conformance_scenario:_02-commit.yml`, ...) -- so alphabetical is
  # filename order here, the same order `SCENARIO_PATHS.sort` already uses to generate them, not a
  # second, independently-chosen ordering that could drift from it.
  i_suck_and_my_tests_are_order_dependent!

  test "the corpus has at least one scenario file" do
    assert SCENARIO_PATHS.any?,
           "no *.yml files found under #{SCENARIOS_DIR} -- every test below is generated from " \
           "this list, so an empty list means this file would verify nothing while still exiting green"
  end

  # COVERAGE, DERIVED FROM THE BINARY'S OWN ROUTE LIST -- NOT A LIST KEPT HERE. A hand-written list
  # of "the routes" in this file would be one more description of the route table that can drift
  # from it, which is the gap itself, not a decoration on it. conformance/routes.txt is the
  # binary's own output, pinned to it by a Rust test (ROUTES_PATH above), so a route added to the
  # server is covered by this test with NO EDIT HERE: some scenario step's request either reaches
  # it or none does, and the failure names it.
  #
  # NO SERVER NEEDED, and always runs (never skips) -- same as "the corpus has at least one
  # scenario file" above. Matching a request to a route is string work, not an HTTP call: this
  # test reads every scenario file's REQUESTS ONLY (never `expect:`) and asks which listed route
  # each one would reach, entirely offline.
  #
  # AN EMPTY LIST IS REFUSED BEFORE IT IS TRUSTED. `uncovered` below is the list minus whatever the
  # scenarios reach, and an empty list minus anything is empty: a truncated or missing routes.txt
  # would let this test pass while checking nothing -- the way the engine's own architecture guards
  # once passed over a glob that had stopped matching any file at all. A line that does not parse
  # as `METHOD /path` is refused for the same reason: skipped, it would shrink the list silently.
  # Both are `flunk` preconditions, like run_scenario's schema check below: they count toward
  # Minitest's assertion total only when they fire.
  test "every route the binary prints is exercised by at least one scenario" do
    if ROUTE_LINES.empty?
      flunk "#{ROUTES_PATH} is missing or lists no routes -- regenerate it with " \
            "`cargo run -q -p tinkerex-sync -- routes > conformance/routes.txt`. This test checks " \
            "every scenario against that list, so an empty one would pass while checking nothing."
    end
    malformed = ROUTE_LINES.grep_v(ROUTE_LINE_RE)
    flunk "#{ROUTES_PATH}: lines that are not `METHOD /path`: #{malformed.inspect}" if malformed.any?

    stale = COVERAGE_EXCEPTIONS.keys - ROUTE_LINES
    assert stale.empty?,
           "COVERAGE_EXCEPTIONS names route(s) conformance/routes.txt no longer lists -- the " \
           "route was renamed or removed, so this exception (and its stated reason) is stale and " \
           "must be updated or dropped: #{stale.join(', ')}"

    covered = Set.new
    SCENARIO_PATHS.each do |scenario_path|
      YAML.load_file(scenario_path).fetch("steps").each do |step|
        request = step.fetch("request")
        route = route_for(method: request.fetch("method"), path: request.fetch("path"))
        covered << route if route
      end
    end

    uncovered = ROUTE_LINES - covered.to_a - COVERAGE_EXCEPTIONS.keys
    assert uncovered.empty?,
           "no scenario step exercises: #{uncovered.join(', ')} -- add a step that calls it, or " \
           "add it to COVERAGE_EXCEPTIONS (test/conformance_test.rb) with a reason"
  end

  # ONE TEST PER SCENARIO FILE, not one test for the whole corpus and not one test per step. Per
  # file: a failure in scenario A must not prevent scenario B from running and reporting its own
  # result, which one shared test would lose (an exception in the middle stops that whole method).
  # Per step would be the other direction: a step's request can depend on an EARLIER step's
  # $capture within the same scenario (conformance/runner.rb: "One Matcher instance owns the
  # $capture/$ref bindings for a single scenario's run start to finish"), so steps are not
  # independent and splitting them into separate tests would need to either replay every prior step
  # first (real HTTP calls, repeated) or share matcher state across test methods, which Minitest
  # gives no supported way to do.
  SCENARIO_PATHS.each do |scenario_path|
    test "conformance scenario: #{File.basename(scenario_path)}" do
      if ENV["SYNC_SERVER_URL"].to_s.strip.empty?
        skip "SYNC_SERVER_URL not set -- this test needs a live server (see conformance/README.md " \
             "and bin/conformance-record's own usage comment). rake test is otherwise unaffected."
      end

      # SYNC_SERVER_URL being set is an explicit opt-in to a live run -- a missing token at that
      # point is a misconfiguration to report loudly, not a second reason to skip quietly. Skipping
      # here would recreate exactly the "reports success having asserted nothing" trap this file
      # otherwise exists to avoid.
      refute ENV["SYNC_DEVICE_TOKEN"].to_s.strip.empty?,
             "SYNC_SERVER_URL is set but SYNC_DEVICE_TOKEN is not -- both are required, the same " \
             "as bin/conformance-record's own usage."

      run_scenario(scenario_path)
    end
  end

  private

  # A bare "{{name}}" path is schema.json's OTHER accepted shape for request.path -- its own
  # comment names exactly one reason it exists: "a presigned chunk-upload/download URL (PUT/GET
  # /v1/chunks/blob/:user_id/:hash)... there is no server-supplied field for the exp/sig query
  # params separately". So a PUT there is unambiguously the blob upload and a GET the blob
  # download, by construction, not by guessing from the captured name -- and that holds regardless
  # of which endpoint MINTED the URL: a share-download-minted URL (10-share-links.yml) reaches this
  # identical route through the identical local-tier presign a chunks/download-minted one does.
  BLOB_PLACEHOLDER_RE = /\A\{\{\w+\}\}\z/
  BLOB_ROUTES = {
    "PUT" => "PUT /v1/chunks/blob/:user_id/:hash", "GET" => "GET /v1/chunks/blob/:user_id/:hash"
  }.freeze

  # The conformance/routes.txt line one scenario step's request would reach -- or nil when it
  # reaches none (no step in the corpus does that today; one that did would be probing an unknown
  # path, which is a scenario's own business and not this coverage check's). The bare-placeholder
  # shape above is handled first and separately, because a literal "{{name}}" is not a path at all
  # (this test runs with no server, so there is nothing to interpolate it from even if it wanted to).
  #
  # A {{name}} placeholder EMBEDDED in an otherwise-literal path (e.g. a captured sibling's node_id
  # in 07-conflicts.yml's last two steps) is swapped for a fixed dummy segment, because a `:param`
  # segment accepts any non-empty, non-slash text: the SHAPE matches identically whether or not the
  # real value is knowable at this offline point. When more than one route matches, the one with
  # the most literal segments wins -- the server's own router's rule (a static segment beats a
  # parameter), so `POST /v1/nodes/symlink` is never counted as a parameterised sibling.
  def route_for(method:, path:)
    verb = method.upcase

    if BLOB_PLACEHOLDER_RE.match?(path)
      route = BLOB_ROUTES[verb]
      # Neither of the two verbs this shape can mean -- a POST/DELETE to a bare {{name}} path
      # would be a genuinely new, uncovered request shape, not a routing question this method can
      # silently shrug off.
      raise "route_for: #{verb} to a bare {{name}} path -- not one of the two presigned " \
            "chunk-blob verbs (PUT upload / GET download); either this scenario step is miscoded " \
            "or schema.json's own documented reason for this path shape has changed" unless route
      return route
    end

    segments = path.gsub(/\{\{\w+\}\}/, "x").split("/", -1)
    matches = ROUTE_LINES.filter_map do |line|
      route_verb, route_path = line.split(" ", 2)
      next unless route_verb == verb && route_path

      pattern = route_path.split("/", -1)
      next unless pattern.size == segments.size
      next unless pattern.zip(segments).all? { |want, got| want.start_with?(":") ? !got.empty? : want == got }

      [ pattern.count { |segment| !segment.start_with?(":") }, line ]
    end
    matches.max_by(&:first)&.last
  end

  # Validates, then executes every step in order against ENV["SYNC_SERVER_URL"], sharing ONE
  # Conformance::Matcher for the whole scenario so a later step can {{interpolate}} or $ref a value
  # an earlier step's $capture bound.
  def run_scenario(scenario_path)
    scenario = YAML.load_file(scenario_path)

    # SCHEMA VALIDATION FIRST, ALWAYS, BEFORE A SINGLE REQUEST GOES OUT. A malformed scenario (a
    # step missing `expect`, a stray key, a method outside the enum) must fail as "malformed
    # scenario, fix the YAML," not as whatever confusing HTTP error or NoMethodError its first bad
    # step happens to trigger three lines into code that assumes a valid shape.
    schema_errors = SCHEMA.validate(scenario).to_a
    if schema_errors.any?
      flunk <<~MSG
        #{scenario_path} does not conform to conformance/schema.json:
        #{schema_errors.map { |e| "  - #{e['error']}" }.join("\n")}
      MSG
    end

    matcher = Conformance::Matcher.new
    base_uri = ENV.fetch("SYNC_SERVER_URL")
    device_token = ENV.fetch("SYNC_DEVICE_TOKEN")

    scenario.fetch("steps").each do |step|
      request = step.fetch("request")
      expect  = step.fetch("expect")

      method  = request.fetch("method")
      path    = matcher.interpolate(request.fetch("path"))
      query   = request["query"] && deep_interpolate(request["query"], matcher)
      body    = request["body"]  && deep_interpolate(request["body"], matcher)
      # {{name}} resolves here too, same as path/query/body, and the same as bin/conformance-record
      # does it -- see that file's own comment on the identical line. A scenario authenticating as
      # a second, dynamically-enrolled device names its captured device_token in a header; without
      # this, the verifier would replay a literal, unresolved "{{device_b_token}}" and get a 401
      # that has nothing to do with what the step is actually testing.
      headers = default_headers_for(body).merge("Authorization" => "Bearer #{device_token}")
                                          .merge(request["headers"] ? deep_interpolate(request["headers"], matcher) : {})

      status, actual_body = perform_request(base_uri:, method:, path:, query:, body:, headers:)

      # A Conformance::Mismatch already names the JSON path that disagreed (runner.rb's own
      # contract: "always names the JSON path that failed"). flunk with that message verbatim,
      # prefixed with WHICH scenario and step it came from, rather than let it surface as an
      # uncaught exception -- an Error in Minitest's vocabulary, wrapped in a Ruby backtrace --
      # instead of a clean, greppable Failure.
      begin
        matcher.match!(expect.fetch("status"), status, "status")
        matcher.match!(expect["body"], actual_body, "body") if expect.key?("body")
        # A real Minitest assertion, not just a raise/rescue -- match! itself has no notion of
        # Minitest's assertion counter, so without this a scenario that passes every one of its
        # steps would report 0 assertions regardless of how many fields it actually checked, and
        # "N assertions" in the suite's own summary would stop meaning anything for this file.
        assert true, "#{scenario_path} / #{step.fetch('name')}: status and body matched"
      rescue Conformance::Mismatch => e
        flunk "#{scenario_path} / #{step.fetch('name')}: #{e.message}"
      end
    end
  end

  # Interpolates {{name}} into every String reachable inside `value` (recursing through Hash/
  # Array), for both request.query and request.body. Deliberately the same shape as
  # bin/conformance-record's own deep_interpolate: both need identical recursive-descent behaviour
  # over the same request shapes, but the RECORDER writes expectations and the VERIFIER only reads
  # and checks them -- different enough jobs that they stay two small standalone programs rather
  # than sharing a third file for eight lines of Hash/Array recursion. The part that must not drift
  # between them -- what {{name}} actually resolves to -- is Conformance::Matcher#interpolate
  # itself, in conformance/runner.rb, which both this method and the recorder call into; that is the
  # shared piece runner.rb's own header comment is about, not this recursion.
  def deep_interpolate(value, matcher)
    case value
    when String then matcher.interpolate(value)
    when Hash then value.transform_values { |v| deep_interpolate(v, matcher) }
    when Array then value.map { |v| deep_interpolate(v, matcher) }
    else value
    end
  end

  # Same rule, same reason, as bin/conformance-record's own default_headers_for: a Hash/Array
  # body is a real JSON API call and defaults to application/json; a bare String body is raw bytes
  # bound for the presigned chunk-blob PUT and defaults to application/octet-stream -- what those
  # bytes are, and what every recording sent. (The Rails host the corpus was first recorded against
  # parsed any application/json-labelled body before its controller ran and 400'd raw bytes that
  # were not also valid JSON; the Rust server reads the blob PUT's body as bytes whatever its
  # label.) A step's own `headers:` is merged in after this, in run_scenario, so it always wins.
  def default_headers_for(body)
    {
      "Content-Type" => (body.is_a?(String) ? "application/octet-stream" : "application/json"),
      "Accept" => "application/json"
    }
  end

  # Same shape as bin/conformance-record's perform_http, trimmed: the verifier never writes a
  # recording back, so there is no record_value / dirty-tracking / YAML-dump half to carry over --
  # only "send the request, parse the response" survives.
  #
  # REQUEST/RESPONSE ENCODING: byte-for-byte the same rule as bin/conformance-record's own
  # perform_http, and it must be -- this is the code that REPLAYS what that tool recorded, so a
  # divergence here would make a scenario pass while recording and fail while verifying (or vice
  # versa) for a reason that has nothing to do with the server. A bare String body goes out
  # verbatim (never JSON.generate'd); a response is JSON.parse'd only when its Content-Type says
  # application/json, and is otherwise kept as the literal raw String. See the recorder's own
  # comment on perform_http for the full argument -- 09-chunks.yml's hydration steps are the case
  # this exists for.
  def perform_request(base_uri:, method:, path:, query:, body:, headers:)
    uri = URI.join(base_uri, path)
    uri.query = URI.encode_www_form(query) if query && !query.empty?

    request_class = REQUEST_CLASS.fetch(method) do
      raise "unsupported HTTP method #{method.inspect} -- schema.json's request.method enum only " \
            "allows GET/POST/PUT/DELETE, so this scenario should have failed schema validation first"
    end
    request = request_class.new(uri)
    headers.each { |name, value| request[name] = value }
    if body
      request.body = body.is_a?(String) ? body : JSON.generate(body)
    end

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }

    raw = response.body.to_s
    actual_body =
      if raw.strip.empty?
        nil
      elsif response.content_type == "application/json"
        JSON.parse(raw)
      else
        raw.dup.force_encoding(Encoding::UTF_8)
      end
    [ response.code.to_i, actual_body ]
  rescue JSON::ParserError
    raise "#{method} #{uri}: response was not valid JSON (status #{response&.code}): #{raw.inspect}"
  end
end
