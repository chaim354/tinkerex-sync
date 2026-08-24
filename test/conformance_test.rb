# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require "yaml"
require "pathname"
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
# lesson) -- so there is no in-process fake standing in when one is not configured, unlike every
# other file under test/, which boots test/dummy and never leaves the process. `rake test` must
# still exit green with no server configured (nobody without one should have their run broken by
# this file), so every per-scenario test below skips on ENV["SYNC_SERVER_URL"] rather than failing
# or erroring.
#
# THAT SKIP IS INVISIBLE TO ANYTHING INSIDE THIS SUITE. A skipped test and an executed, passing
# test both report "not red," and nothing in Minitest lets one test assert about another test's own
# skip -- so the guarantee that this file actually ran for real, rather than quietly skipping,
# belongs to the CALLER, not to this file. .github/workflows/ci.yml's conformance job sets both env
# vars below AND parses the run's own summary line for a nonzero skip count, failing the CI step if
# it finds one. Running this suite by hand with no server is the one case where a skip is not just
# expected but correct.
#
# THE ONE TEST THAT NEVER SKIPS: "the corpus has at least one scenario file". Every test below it is
# GENERATED from Dir.glob's result at class-definition time. If that glob ever silently returned
# nothing -- a typo'd path, conformance/scenarios/ renamed out from under this file -- there would
# be nothing to generate, nothing to skip, and nothing to run: `rake test` would report a clean 0
# runs for this file's would-be coverage and look exactly like success. This one test has no server
# dependency, always runs, and turns that failure mode into a loud, ordinary red.
class ConformanceTest < ActiveSupport::TestCase
  SCENARIOS_DIR = File.expand_path("../conformance/scenarios", __dir__)
  SCHEMA_PATH   = File.expand_path("../conformance/schema.json", __dir__)

  # Parsed once at class-definition time, not once per scenario -- schema.json cannot change
  # mid-run, so re-parsing it per scenario would be pure waste.
  SCHEMA = JSONSchemer.schema(Pathname.new(SCHEMA_PATH))

  DEFAULT_HEADERS = { "Content-Type" => "application/json", "Accept" => "application/json" }.freeze
  REQUEST_CLASS = {
    "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post, "PUT" => Net::HTTP::Put, "DELETE" => Net::HTTP::Delete
  }.freeze

  SCENARIO_PATHS = Dir.glob(File.join(SCENARIOS_DIR, "*.yml")).sort.freeze

  test "the corpus has at least one scenario file" do
    assert SCENARIO_PATHS.any?,
           "no *.yml files found under #{SCENARIOS_DIR} -- every test below is generated from " \
           "this list, so an empty list means this file would verify nothing while still exiting green"
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
      unless ENV["SYNC_SERVER_URL"].present?
        skip "SYNC_SERVER_URL not set -- this test needs a live server (see conformance/README.md " \
             "and bin/conformance-record's own usage comment). rake test is otherwise unaffected."
      end

      # SYNC_SERVER_URL being set is an explicit opt-in to a live run -- a missing token at that
      # point is a misconfiguration to report loudly, not a second reason to skip quietly. Skipping
      # here would recreate exactly the "reports success having asserted nothing" trap this file
      # otherwise exists to avoid.
      assert ENV["SYNC_DEVICE_TOKEN"].present?,
             "SYNC_SERVER_URL is set but SYNC_DEVICE_TOKEN is not -- both are required, the same " \
             "as bin/conformance-record's own usage."

      run_scenario(scenario_path)
    end
  end

  private

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
      headers = DEFAULT_HEADERS.merge("Authorization" => "Bearer #{device_token}").merge(request["headers"] || {})

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

  # Same shape as bin/conformance-record's perform_http, trimmed: the verifier never writes a
  # recording back, so there is no record_value / dirty-tracking / YAML-dump half to carry over --
  # only "send the request, parse the response" survives.
  def perform_request(base_uri:, method:, path:, query:, body:, headers:)
    uri = URI.join(base_uri, path)
    uri.query = URI.encode_www_form(query) if query && !query.empty?

    request_class = REQUEST_CLASS.fetch(method) do
      raise "unsupported HTTP method #{method.inspect} -- schema.json's request.method enum only " \
            "allows GET/POST/PUT/DELETE, so this scenario should have failed schema validation first"
    end
    request = request_class.new(uri)
    headers.each { |name, value| request[name] = value }
    request.body = JSON.generate(body) if body

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }

    raw = response.body.to_s
    actual_body = raw.strip.empty? ? nil : JSON.parse(raw)
    [ response.code.to_i, actual_body ]
  rescue JSON::ParserError
    raise "#{method} #{uri}: response was not valid JSON (status #{response&.code}): #{raw.inspect}"
  end
end
