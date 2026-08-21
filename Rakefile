# Standard Rails-engine Rakefile shape (what `rails plugin new --mountable` generates), hand-
# written rather than generated -- see test/dummy/config/boot.rb for why the generator itself
# was not run. `rake -f engines/tinkerex-sync/Rakefile test`, or `cd engines/tinkerex-sync &&
# bundle exec rake test`, runs the engine's OWN suite against test/dummy, with no dependency on
# the host's test/test_helper.rb (config/ci.rb's "engine" gate calls exactly this).
require "bundler/setup"

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  # "test/**/*_test.rb", NOT "test/dummy/**" too -- FileList resolves relative to Dir.pwd (this
  # directory, when invoked as documented above), and test/dummy/ deliberately contains no
  # *_test.rb files of its own (it is the host stand-in the tests under test/ run AGAINST, not a
  # second suite), so no explicit exclusion is needed; noted here so it is not "discovered" as a
  # missing exclusion later.
  t.pattern = "test/**/*_test.rb"
  t.verbose = false
end

task default: :test

# THE HOST'S SUITE RUNS IN ITS OWN PROCESS, because two Rails applications cannot boot in one. The
# default `test` task boots test/dummy (proving the engine needs only the three declared models);
# this boots host/ (proving the thing an operator actually runs works). Neither can stand in for the
# other, and running them together would just mean whichever loaded first won.
Rake::TestTask.new("test:host") do |t|
  t.libs << "host/test"
  t.pattern = "host/test/**/*_test.rb"
  t.verbose = false
end
