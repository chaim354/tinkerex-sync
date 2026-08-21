# This file's PRESENCE, not its content, is what matters here: `Rails::Application.find_root`
# walks up from config/application.rb's own directory looking for a `config.ru` to mark the app
# root, falling back to Dir.pwd only if none is ever found -- and the MONOREPO ROOT has its own
# config.ru four directories up. Without this file, Rails.root silently resolved to the outer
# repo instead of this dummy app (verified: `bin/rails runner 'puts Rails.root'` printed the
# monorepo root before this file existed), which would have pointed config/database.yml's
# `storage/test.sqlite3` at the HOST'S OWN storage/ directory -- a dummy app quietly testing
# against, and potentially corrupting, real development data. Standard Rails app content; never
# actually run as a Rack server.
require_relative "config/environment"

run Rails.application
Rails.application.load_server
