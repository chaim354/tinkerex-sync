# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_01_01_000002) do
  create_table "changelog_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "node_id", null: false
    t.string "op", null: false
    t.bigint "seq", null: false
    t.integer "user_id", null: false
    t.string "version_id"
    t.index ["user_id", "seq"], name: "index_changelog_entries_on_user_id_and_seq", unique: true
  end

  create_table "chunks", force: :cascade do |t|
    t.string "chunk_hash", null: false
    t.datetime "created_at", null: false
    t.integer "refcount", default: 0, null: false
    t.bigint "size", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "chunk_hash"], name: "index_chunks_on_user_id_and_chunk_hash", unique: true
    t.index ["user_id", "refcount"], name: "index_chunks_on_user_id_and_refcount"
  end

  create_table "conflicts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "current_version_id", null: false
    t.string "incoming_version_id", null: false
    t.string "node_id", null: false
    t.datetime "resolved_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "node_id", "incoming_version_id"], name: "index_conflicts_on_user_node_incoming", unique: true
    t.index ["user_id", "resolved_at"], name: "index_conflicts_on_user_id_and_resolved_at"
  end

  create_table "devices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_seen_at"
    t.string "name", default: "device", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["token_digest"], name: "index_devices_on_token_digest", unique: true
    t.index ["user_id"], name: "index_devices_on_user_id"
  end

  create_table "file_locks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_id", null: false
    t.datetime "expires_at", null: false
    t.string "node_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "expires_at"], name: "index_file_locks_on_user_id_and_expires_at"
    t.index ["user_id", "node_id"], name: "index_file_locks_on_user_id_and_node_id", unique: true
  end

  create_table "manifest_chunks", force: :cascade do |t|
    t.string "chunk_hash", null: false
    t.bigint "length", null: false
    t.string "manifest_id", null: false
    t.bigint "offset", null: false
    t.integer "seq", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "manifest_id", "seq"], name: "index_manifest_chunks_on_user_id_and_manifest_id_and_seq", unique: true
  end

  create_table "nodes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "current_version_id"
    t.boolean "deleted", default: false, null: false
    t.string "kind", null: false
    t.integer "mode"
    t.bigint "mtime"
    t.string "name", null: false
    t.string "node_id", null: false
    t.string "parent_node_id"
    t.binary "symlink_target"
    t.datetime "updated_at", null: false
    t.bigint "updated_seq", default: 0, null: false
    t.integer "user_id", null: false
    t.index ["user_id", "node_id"], name: "index_nodes_on_user_id_and_node_id", unique: true
    t.index ["user_id", "parent_node_id"], name: "index_nodes_on_user_id_and_parent_node_id"
    t.index ["user_id"], name: "index_nodes_on_user_id"
  end

  create_table "pending_commits", force: :cascade do |t|
    t.string "base_version_id"
    t.string "commit_id", null: false
    t.datetime "created_at", null: false
    t.bigint "device_id"
    t.string "manifest_id", null: false
    t.text "manifest_json", null: false
    t.integer "mode"
    t.bigint "mtime"
    t.string "name", null: false
    t.string "node_id", null: false
    t.string "parent_node_id"
    t.bigint "size", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "commit_id"], name: "index_pending_commits_on_user_id_and_commit_id", unique: true
  end

  create_table "share_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "manifest_id", null: false
    t.string "node_id", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "version_id", null: false
    t.index ["token_digest"], name: "index_share_links_on_token_digest", unique: true
    t.index ["user_id", "version_id"], name: "index_share_links_on_user_id_and_version_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.bigint "head_seq", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_id"
    t.string "manifest_id", null: false
    t.string "node_id", null: false
    t.string "parent_version_id"
    t.boolean "pinned", default: false, null: false
    t.bigint "size", default: 0, null: false
    t.integer "user_id", null: false
    t.string "version_id", null: false
    t.index ["user_id", "node_id", "id"], name: "index_versions_on_user_id_and_node_id_and_id"
    t.index ["user_id", "version_id"], name: "index_versions_on_user_id_and_version_id", unique: true
  end

  add_foreign_key "changelog_entries", "users"
  add_foreign_key "chunks", "users"
  add_foreign_key "conflicts", "users"
  add_foreign_key "devices", "users"
  add_foreign_key "file_locks", "users"
  add_foreign_key "manifest_chunks", "users"
  add_foreign_key "nodes", "users"
  add_foreign_key "pending_commits", "users"
  add_foreign_key "share_links", "users"
  add_foreign_key "versions", "users"
end
