# THE SMALLEST Node THAT SATISFIES WHAT THE ENGINE ACTUALLY USES. The real host's Node additionally
# carries `content_hash`, `storage_path` and `size` -- columns the SHARE/S3 FileLayer adapters
# populate (host-side, per CLAUDE.md §14a/§14b) and the maker web layer displays. Grepped every
# reference to a lowercase `node.<attr>` under engines/tinkerex-sync/app and lib before writing
# this: none of the three appear. `size` came up once, indirectly -- one moved test
# (trash_flow_test.rb's `tombstone!` helper) originally passed `size:` to `nodes.create!` when
# building a fixture directly; TrashController#index (engine code) gets a tombstone's size
# exclusively from `Sync.load_version_sizes`, never `node.size` (confirmed by reading the
# controller, not assumed), so that kwarg was genuinely inert and was dropped when the test moved
# rather than growing this schema for a column nothing in the engine ever reads back.
#
# `children` (host's own `user.nodes.present.where(parent_node_id:)`) is NOT ported -- nothing
# under engines/tinkerex-sync calls `node.children`; every engine query that needs a node's
# children builds it inline (Sync::SubtreeDelete, Sync::Search's recursive CTE). Copying an unused
# convenience method would just be a second, silently-stale description of the same query.
class Node < ApplicationRecord
  belongs_to :user

  KINDS = %w[file dir symlink].freeze

  validates :node_id, presence: true, uniqueness: { scope: :user_id }
  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }

  # Read by Sync::Tree/Sync::Changes (`node.file?`, `node.symlink?`) -- see engines/tinkerex-sync/
  # app/services/sync/{tree,changes}.rb. `dir?` has no caller under engines/tinkerex-sync today;
  # kept anyway (not "ported down" to two methods) because KINDS itself already names all three
  # and a Node that answers `file?`/`symlink?` but not `dir?` would be a stranger API than the
  # host's, for a saving of one line.
  def dir? = kind == "dir"
  def file? = kind == "file"
  def symlink? = kind == "symlink"

  scope :present, -> { where(deleted: false) }
end
