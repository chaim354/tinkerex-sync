# frozen_string_literal: true

# THE HOST'S OWN TEST HELPER, SEPARATE FROM THE GEM'S, because two Rails applications cannot boot in
# one process. The gem's suite boots test/dummy to prove the engine needs nothing but the three
# declared models; this one boots the real host to prove the thing an operator actually runs works.
# They answer different questions and must stay in different processes to answer either.
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
end
