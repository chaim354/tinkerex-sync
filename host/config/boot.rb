# THE STANDALONE SYNC HOST's boot. One level shallower than test/dummy's, because this app lives at
# host/ rather than test/dummy/ -- it shares the repository's single Gemfile, which is the whole
# point: the host IS this gem plus the three models the engine declares it needs.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../Gemfile", __dir__)

require "bundler/setup"
