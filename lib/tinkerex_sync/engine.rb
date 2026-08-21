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

    # THE ROUTE DRAWER IS PLAIN-REQUIRED, AND IT LIVES AT lib/tinkerex_sync/v1_routes.rb RATHER THAN
    # config/routes.rb. An earlier version of this comment said an engine's config/routes.rb is
    # "evaluated by Rails only when the engine is MOUNTED" -- that is exactly the misunderstanding
    # that cost an hour: Rails::Engine adds its own `routes` initializer which evaluates that file
    # whether or not anything mounts the engine, so the drawer sitting there was loaded TWICE and
    # Ruby said so (`already initialized constant Sync::V1_ROUTES`). Moving it out of the reserved
    # path is the fix; the require below is then the only thing that loads it.
    #
    # This engine is deliberately not mounted -- see v1_routes.rb's header: its routes interleave
    # with the host's inside one `namespace :v1`, which a mount cannot express. So the host and the
    # dummy call Sync.draw_v1_routes themselves, and the definition must exist before either does.
    #
    # `require`, not autoload: routes are drawn during initialization, before Zeitwerk is ready --
    # the same reason sync_module.rb is required rather than autoloaded.
    config.before_initialize { require_relative "v1_routes" }

    # `lib/` IS NOT AN AUTOLOAD ROOT FOR A Rails::Engine BY DEFAULT -- ONLY `app/*` IS, FOR FREE.
    # The host gets its `lib/sync/postgres_pooler_check.rb` autoloaded via `config.autoload_lib`
    # in config/application.rb, but that method is defined on `Rails::Application::Configuration`
    # only (railties' lib/rails/application/configuration.rb) -- there is no `Rails::Engine`
    # equivalent to call. Verified `uninitialized constant Sync::PostgresPoolerCheck` the moment
    # lib/sync/postgres_pooler_check.rb moved here unchanged; this initializer is the fix,
    # replicating `autoload_lib`'s own body (same two array pushes, same `ignore` call) rather
    # than inventing a different shape for the same problem.
    #
    # There IS one shared Zeitwerk loader for the whole boot, `Rails.autoloaders.main` -- engines
    # do not get a private loader of their own merely by being isolated (grepped railties itself:
    # `Zeitwerk::Loader.new` appears exactly once, in rails/autoloaders.rb; `isolate_namespace` is
    # naming/config conventions only, never a second loader). That is also WHY the models and
    # services moved earlier in this same commit sequence autoloaded correctly with no equivalent
    # step: `app/*` roots are pushed onto that one shared loader automatically, by Rails::Engine's
    # own `:set_autoload_paths` initializer, for every engine.
    #
    # THE TWO ARRAY PUSHES RUN DIRECTLY IN THE CLASS BODY, NOT INSIDE `initializer do ... end` --
    # TRIED FIRST AND FAILED LOUDLY: Rails' own `:set_autoload_paths` initializer reads and
    # FREEZES `config.autoload_paths`/`config.eager_load_paths` early in the boot sequence, well
    # before a plainly-declared custom `initializer` block (which sorts, by default, into the
    # general run AFTER that point) ever gets to run -- `can't modify frozen Array: []` the moment
    # this tried to push into one from inside such a block. `config.autoload_lib` itself
    # (railties' application/configuration.rb) is called directly in `Rails::Application`'s own
    # class body for the identical reason; this matches that timing rather than rediscovering it.
    lib = root.join("lib")
    config.autoload_paths << lib.to_s
    config.eager_load_paths << lib.to_s

    # TWO SUBDIRECTORIES ARE IGNORED, FOR TWO DIFFERENT REASONS -- do not collapse this to one
    # generic "ignore lib/tasks like the host does" comment, because only the first is that.
    #
    #   - `lib/tasks/` matches the host's own `ignore: %w[assets tasks]` (this engine ships no
    #     `lib/assets`, so only `tasks` is real here). A `.rake` file has no `.rb` extension so
    #     Zeitwerk's own file scan already skips it, but an unignored directory still gets walked
    #     as a namespace on every eager load for zero benefit.
    #   - `lib/tinkerex_sync/` MUST be ignored, and skipping it is not optional the way `tasks` is:
    #     this is the GEM'S OWN bootstrap directory (tinkerex_sync.rb, engine.rb -- this very file
    #     -- sync_module.rb, version.rb), already loaded by plain `require`, never meant to be
    #     autoloaded at all. Adding `lib` to the autoload roots above puts it in Zeitwerk's path
    #     for the first time, and its filenames do not match what Zeitwerk expects from them --
    #     `tinkerex_sync/engine.rb` is expected to define `TinkerexSync::Engine`, and it defines
    #     `Sync::Engine` (that mismatch is this whole file's `module Sync` reason to exist), and
    #     `tinkerex_sync/version.rb` defines the constant `TinkerexSync::VERSION`, not the class
    #     `TinkerexSync::Version` its path implies. `bin/rails zeitwerk:check` FAILED with
    #     `uninitialized constant TinkerexSync::Engine` the moment `lib` was added without this --
    #     found by running the check, not reasoned in advance.
    #
    # BOTH IGNORES GO IN AN INITIALIZER, NOT THE CLASS BODY -- direct-in-body was tried first and
    # failed: `Rails.autoloaders` delegates to `Rails.application.autoloaders` (rails.rb), and
    # `Rails.application` is nil at the point this file is `require`d -- that happens from
    # Bundler.require, inside config/application.rb, BEFORE the `Tinkerex::Application <
    # Rails::Application` class below it is even defined. Only an Application subclass's OWN
    # `inherited` hook sets `Rails.application`, and an Engine triggers no such hook, so this
    # engine is *structurally* loaded before any application exists to ask Rails.autoloaders
    # about. `before: :set_autoload_paths` places this call inside Rails::Application#initialize!
    # (where Rails.application is unconditionally already set, by definition of what is calling
    # it) and strictly before the paths above get frozen -- the narrow window that satisfies both
    # this and the array-freeze failure documented above at once.
    initializer "tinkerex_sync.ignore_lib_subdirs", before: :set_autoload_paths do
      Rails.autoloaders.main.ignore(lib.join("tasks"), lib.join("tinkerex_sync"))
    end
  end
end
