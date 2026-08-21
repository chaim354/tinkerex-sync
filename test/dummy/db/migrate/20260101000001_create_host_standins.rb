# The dummy app's OWN description of the three HOST_MODELS tables (lib/tinkerex_sync.rb) --
# deliberately hand-written and deliberately NOT db/engine_schema.rb-style generated from the real
# db/schema.rb, unlike the migration alongside this one. db/schema.rb's users/nodes/devices carry
# the full Devise column set and the share/s3-only node columns (content_hash, storage_path,
# size) -- copying those wholesale would defeat the point of this task (write the SMALLEST
# tables that satisfy what the engine uses), and there is no single generator for "the columns
# three engine model files actually touch" the way there is for "the eight engine tables'
# complete DDL" (lib/engine_schema.rb). See test/dummy/app/models/{user,node,device}.rb for the
# column-by-column justification of what is (and, for Node, is deliberately not) here.
class CreateHostStandins < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.bigint :head_seq, null: false, default: 0
      t.timestamps
    end
    add_index :users, :email, unique: true

    create_table :devices do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false, default: "device"
      t.string :token_digest, null: false
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :devices, :token_digest, unique: true

    create_table :nodes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :node_id, null: false
      t.string :parent_node_id
      t.string :name, null: false
      t.string :kind, null: false
      t.boolean :deleted, null: false, default: false
      t.string :current_version_id
      t.integer :mode
      t.bigint :mtime
      t.binary :symlink_target
      t.bigint :updated_seq, null: false, default: 0
      t.timestamps
    end
    add_index :nodes, [ :user_id, :node_id ], unique: true
    add_index :nodes, [ :user_id, :parent_node_id ]
  end
end
