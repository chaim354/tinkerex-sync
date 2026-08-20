class Sync::Version < ::ApplicationRecord
  belongs_to :user, class_name: "::User"

  validates :version_id, presence: true, uniqueness: { scope: :user_id }
  validates :node_id, presence: true
  validates :manifest_id, presence: true

  # The ordered chunk list for this version's manifest. Explicitly qualified even though
  # nothing in this file's own lexical scope would resolve it otherwise: `class Sync::Version`
  # is the COMPACT form, so Module.nesting here is `[Sync::Version]`, not `[Sync::Version,
  # Sync]` — unlike a `module Sync; class Version; end; end` NESTED form, the compact spelling
  # does not put `Sync` on the lexical scope stack, so a bare `ManifestChunk` would fall
  # straight past it to `Object` and raise NameError the moment nothing top-level answers to
  # that name anymore (Stage 3b Phase A Task 3 moved it to `Sync::ManifestChunk`).
  def manifest_chunks
    Sync::ManifestChunk.where(user_id:, manifest_id:).order(:seq)
  end
end
