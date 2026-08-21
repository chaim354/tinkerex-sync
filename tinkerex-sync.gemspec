require_relative "lib/tinkerex_sync/version"

Gem::Specification.new do |spec|
  spec.name        = "tinkerex-sync"
  spec.version     = TinkerexSync::VERSION
  spec.authors     = [ "Charles Schwartz" ]
  spec.summary     = "Local-first file sync engine: content-addressed chunks, immutable versions, a per-user changelog."
  spec.description = <<~TEXT
    The sync half of tinkerex, as a mountable Rails engine. Files are split into
    content-defined chunks (FastCDC), content-addressed and deduped; a commit is an
    immutable version pointing at a chunk manifest; devices converge by pulling a
    per-user changelog. Chunk bytes move client-to-storage over presigned URLs and
    never through Rails.

    The host provides User, Node and Device (see TinkerexSync::HOST_MODELS).
  TEXT
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "README.md"]

  # TWO DEPENDENCIES, AND THE LIST IS SHORT BECAUSE IT WAS MEASURED, not guessed: every other gem
  # in the host's Gemfile was checked against its real call sites and is maker-only or
  # host-infrastructure-only. Notably absent: devise/bcrypt (Device authenticates with
  # SecureRandom + SHA256, not passwords), nokogiri/rubyzip/image_processing (preview rendering,
  # all maker), and the solid_* trio (the host chooses its queue adapter; engine jobs are plain
  # ActiveJob).
  spec.add_dependency "rails", ">= 8.1", "< 9"
  spec.add_dependency "aws-sdk-s3", "~> 1"
end
