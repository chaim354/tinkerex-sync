# Byte-identical to the host's app/models/application_record.rb. Every Sync::* model says
# `< ::ApplicationRecord` explicitly (Stage 3b Phase A Task 3's own comment on why: the compact
# `class Sync::Version` form does not put `Sync` on Module.nesting, so an unqualified reference
# would resolve here anyway via top-level fallback -- but `isolate_namespace` makes that fallback
# unreliable, hence the explicit `::`). This is HOST-shaped boilerplate the real app also owns;
# a bare mount needs its own copy, same as ApplicationJob and ApplicationCable below.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
