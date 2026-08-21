# Load the dummy application.
require_relative "application"

# Initialize it -- this is the moment the engine's `isolate_namespace Sync` block, its
# autoload_paths/eager_load_paths pushes, and the "ignore lib/tinkerex_sync" initializer
# (lib/tinkerex_sync/engine.rb) all actually run.
Rails.application.initialize!
