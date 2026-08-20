module Sync
  # `isolate_namespace` DEFINES `table_name_prefix` AS "sync_", AND THAT WOULD BREAK EVERY MODEL.
  # The tables are `versions`, `chunks`, `manifest_chunks` -- they predate the namespace by two
  # years and are named in migrations, in db/schema.rb, in three live deployments' databases, and
  # in every backup archive CLAUDE.md §14i's restore rehearsal exercises. Renaming them is not on
  # the table; the prefix has to go.
  #
  # DEFINED HERE, BEFORE `isolate_namespace` RUNS BELOW -- ORDER IS THE WHOLE FIX, AND GETTING IT
  # BACKWARDS IS SILENT. An earlier draft of this file defined this method AFTER `isolate_namespace
  # Sync`, reasoning that a later `def` simply overrides an earlier one -- true for the IMMEDIATE
  # effect, and wrong for the actual bug: `Rails::Engine#isolate_namespace` (railties'
  # lib/rails/engine.rb) does not just set `table_name_prefix` once, it ALSO registers
  # `ActiveSupport.on_load(:active_record) { mod.singleton_class.redefine_method(:table_name_prefix)
  # { "sync_" } }` -- and that hook fires LATER, when ActiveRecord::Base itself loads during Rails
  # boot, well after this file's own top-level code has already run. A `def self.table_name_prefix`
  # placed below `isolate_namespace` gets silently clobbered the moment ActiveRecord loads:
  # `Sync.table_name_prefix` measured "sync_" and every engine model's table lookup 500'd
  # (`Could not find table 'sync_chunks'`) with zero errors anywhere in this file. Verified against
  # railties 8.1.3.1's actual source, not inferred.
  #
  # Defining it FIRST sidesteps the hook entirely, because `isolate_namespace`'s own table-prefix
  # logic (both the immediate `define_method` and the `on_load` registration) is wrapped in
  # `unless mod.respond_to?(:table_name_prefix)` -- if `Sync` already answers that message before
  # `isolate_namespace Sync` runs, Rails skips BOTH pieces of its own logic and this definition is
  # the only one that ever exists. Immune to load order by construction, not by lexical luck.
  #
  # OVERRIDDEN HERE RATHER THAN PER MODEL, and the alternative was considered: eight explicit
  # `self.table_name = "versions"` lines would also work. This is one line instead of eight and
  # cannot drift out of step with a ninth model. If a ninth engine model ever appears and reads
  # `sync_`-prefixed, this method (or the ordering above it) is why.
  def self.table_name_prefix = ""

  # THE ENGINE. Its module is `Sync`, not `TinkerexSync`, and the gem name differs from the module
  # on purpose -- exactly as `rails` the gem provides `Rails` the module. `Sync` is what 216
  # references in this codebase already say, and Stage 3b Phase A moved the last fifteen top-level
  # engine names under it precisely so this line could be written.
  class Engine < ::Rails::Engine
    # ISOLATED, WHICH IS THE WHOLE POINT (Stage 3b's opening decision): a gem that squats `Version`,
    # `Chunk`, `Conflict` and `FileLock` at top level cannot be given to anyone, and a sellable
    # standalone engine is goal one of the arc. Isolating trades eight generic squatted names for
    # one.
    isolate_namespace Sync
  end
end
