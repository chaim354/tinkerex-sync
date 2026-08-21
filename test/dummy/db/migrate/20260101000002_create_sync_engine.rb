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
# THE PATH REACHES OUTSIDE engines/tinkerex-sync/ ON PURPOSE, AND ONLY FOR AS LONG AS THAT IS TRUE
# (see this dummy's config/boot.rb for the identical caveat about BUNDLE_GEMFILE): tinkerex-sync
# is still consumed from inside the tinkerex monorepo via a `path:` Gemfile source, not yet its
# own repository, so db/engine_schema.rb has nowhere else to live today. Once Phase B's eventual
# `git filter-repo` extraction happens, the gem carries its OWN copy of this migration (Phase B's
# stated plan: "Phase B copies it into the gem near-verbatim" -- lib/engine_schema.rb's header),
# and this `load` line is replaced by that copy, not by another indirection.
#
# CreateSyncEngine's own `add_foreign_key ..., "users"` lines (all eight) are exactly why the
# OTHER migration in this directory (CreateHostStandins) must run first -- Rails runs migrations
# in timestamp order, and this file's timestamp is deliberately later.
load File.expand_path("../../../../../../db/engine_schema.rb", __dir__)
