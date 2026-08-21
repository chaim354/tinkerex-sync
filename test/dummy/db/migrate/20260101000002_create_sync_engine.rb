# THE EIGHT ENGINE TABLES, LOADED FROM db/engine_schema.rb -- NOT A SECOND HAND-WRITTEN
# DESCRIPTION OF THEM. That file already exists precisely to be the one generated, checked,
# regenerate-on-drift description of this DDL (lib/engine_schema.rb; test/engine_schema_test.rb;
# CLAUDE.md §14j) -- authoring a THIRD copy here (after db/schema.rb and db/engine_schema.rb
# itself) is exactly the two-sources-of-truth shape that file's own header warns against, and this
# dummy app's whole reason to exist is to prove the checked-in file is real, runnable DDL. `load`,
# not `require` -- `require` is idempotent per absolute path and this file's class name
# (CreateSyncEngine) must be free to be evaluated fresh; nothing else in this process ever loads
# db/engine_schema.rb, so idempotence is not actually a concern here, but `load` is the honest verb
# for "run this file's top-level code," and matches how test/engine_schema_test.rb's own strong
# check evaluates the identical text (`module_eval(EngineSchema.render, ...)`) rather than treating
# it as a library to require once.
#
# THE PATH IS THIS REPOSITORY'S OWN db/engine_schema.rb. Before the 2026-08-20 extraction it
# reached six levels up into the tinkerex monorepo, because the engine lived at
# engines/tinkerex-sync/ and that file had nowhere else to be. The gem now carries the copy the
# extraction plan named, so this is an ordinary in-repo load and not an indirection at all.
#
# CreateSyncEngine's own `add_foreign_key ..., "users"` lines (all eight) are exactly why the
# OTHER migration in this directory (CreateHostStandins) must run first -- Rails runs migrations
# in timestamp order, and this file's timestamp is deliberately later.
load File.expand_path("../../../../db/engine_schema.rb", __dir__)
