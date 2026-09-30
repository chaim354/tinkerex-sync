CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "email" varchar NOT NULL, "head_seq" bigint DEFAULT 0 NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_users_on_email" ON "users" ("email");
CREATE TABLE "devices" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "last_seen_at" datetime(6), "name" varchar DEFAULT 'device' NOT NULL, "token_digest" varchar NOT NULL, "updated_at" datetime(6) NOT NULL, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_410b63ef65"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE UNIQUE INDEX "index_devices_on_token_digest" ON "devices" ("token_digest");
CREATE INDEX "index_devices_on_user_id" ON "devices" ("user_id");
CREATE TABLE "nodes" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "current_version_id" varchar, "deleted" boolean DEFAULT FALSE NOT NULL, "kind" varchar NOT NULL, "mode" integer, "mtime" bigint, "name" varchar NOT NULL, "node_id" varchar NOT NULL, "parent_node_id" varchar, "symlink_target" blob, "updated_at" datetime(6) NOT NULL, "updated_seq" bigint DEFAULT 0 NOT NULL, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_3ceff5c266"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_nodes_on_user_id" ON "nodes" ("user_id");
CREATE UNIQUE INDEX "index_nodes_on_user_id_and_node_id" ON "nodes" ("user_id", "node_id");
CREATE INDEX "index_nodes_on_user_id_and_parent_node_id" ON "nodes" ("user_id", "parent_node_id");
CREATE TABLE "changelog_entries" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "node_id" varchar NOT NULL, "op" varchar NOT NULL, "seq" bigint NOT NULL, "user_id" integer NOT NULL, "version_id" varchar, CONSTRAINT "fk_rails_d3bc07051d"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE UNIQUE INDEX "index_changelog_entries_on_user_id_and_seq" ON "changelog_entries" ("user_id", "seq");
CREATE TABLE "chunks" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "chunk_hash" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "refcount" integer DEFAULT 0 NOT NULL, "size" bigint DEFAULT 0 NOT NULL, "updated_at" datetime(6) NOT NULL, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_4699b2a9c7"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE UNIQUE INDEX "index_chunks_on_user_id_and_chunk_hash" ON "chunks" ("user_id", "chunk_hash");
CREATE INDEX "index_chunks_on_user_id_and_refcount" ON "chunks" ("user_id", "refcount");
CREATE TABLE "conflicts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "current_version_id" varchar NOT NULL, "incoming_version_id" varchar NOT NULL, "node_id" varchar NOT NULL, "resolved_at" datetime(6), "updated_at" datetime(6) NOT NULL, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_06b72a4f99"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_conflicts_on_user_id_and_resolved_at" ON "conflicts" ("user_id", "resolved_at");
CREATE UNIQUE INDEX "index_conflicts_on_user_node_incoming" ON "conflicts" ("user_id", "node_id", "incoming_version_id");
CREATE TABLE "file_locks" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "device_id" bigint NOT NULL, "expires_at" datetime(6) NOT NULL, "node_id" varchar NOT NULL, "updated_at" datetime(6) NOT NULL, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_cdf2ba9cec"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_file_locks_on_user_id_and_expires_at" ON "file_locks" ("user_id", "expires_at");
CREATE UNIQUE INDEX "index_file_locks_on_user_id_and_node_id" ON "file_locks" ("user_id", "node_id");
CREATE TABLE "manifest_chunks" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "chunk_hash" varchar NOT NULL, "length" bigint NOT NULL, "manifest_id" varchar NOT NULL, "offset" bigint NOT NULL, "seq" integer NOT NULL, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_e0d78b394d"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE UNIQUE INDEX "index_manifest_chunks_on_user_id_and_manifest_id_and_seq" ON "manifest_chunks" ("user_id", "manifest_id", "seq");
CREATE TABLE "pending_commits" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "base_version_id" varchar, "commit_id" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "device_id" bigint, "manifest_id" varchar NOT NULL, "manifest_json" text NOT NULL, "mode" integer, "mtime" bigint, "name" varchar NOT NULL, "node_id" varchar NOT NULL, "parent_node_id" varchar, "size" bigint DEFAULT 0 NOT NULL, "updated_at" datetime(6) NOT NULL, "user_id" integer NOT NULL, CONSTRAINT "fk_rails_1e53072fb6"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE UNIQUE INDEX "index_pending_commits_on_user_id_and_commit_id" ON "pending_commits" ("user_id", "commit_id");
CREATE TABLE "share_links" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "expires_at" datetime(6), "manifest_id" varchar NOT NULL, "node_id" varchar NOT NULL, "revoked_at" datetime(6), "token_digest" varchar NOT NULL, "updated_at" datetime(6) NOT NULL, "user_id" integer NOT NULL, "version_id" varchar NOT NULL, CONSTRAINT "fk_rails_8d57437e3a"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE UNIQUE INDEX "index_share_links_on_token_digest" ON "share_links" ("token_digest");
CREATE INDEX "index_share_links_on_user_id_and_version_id" ON "share_links" ("user_id", "version_id");
CREATE TABLE "versions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "created_at" datetime(6) NOT NULL, "device_id" bigint, "manifest_id" varchar NOT NULL, "node_id" varchar NOT NULL, "parent_version_id" varchar, "pinned" boolean DEFAULT FALSE NOT NULL, "size" bigint DEFAULT 0 NOT NULL, "user_id" integer NOT NULL, "version_id" varchar NOT NULL, CONSTRAINT "fk_rails_914f13c63b"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_versions_on_user_id_and_node_id_and_id" ON "versions" ("user_id", "node_id", "id");
CREATE UNIQUE INDEX "index_versions_on_user_id_and_version_id" ON "versions" ("user_id", "version_id");
