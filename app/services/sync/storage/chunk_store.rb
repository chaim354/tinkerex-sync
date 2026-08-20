module Sync
  module Storage
    # Base + factory for the content-addressed chunk store. Concrete stores
    # (S3/R2, Memory) presign PUT (upload missing chunks) and GET (hydration) so file
    # bytes flow client <-> storage directly — Rails never handles chunk bytes.
    #
    # STAGE 3b PHASE A TASK 4 moved this (and its three concrete stores) from the bare
    # top-level `Storage` module to `Sync::Storage` — the engine's own chunk data plane
    # namespaced beside every other sync-side constant, closing the second of the two
    # top-level names the engine squatted (CLAUDE.md §14j; `LibraryChannel` was the other,
    # app/channels/sync/library_channel.rb). NESTED module style, not the compact
    # `class Sync::Storage::ChunkStore` form Task 3 used for the AR models: this file's own
    # `ChunkStore.build` resolves its three siblings (`MemoryChunkStore`, `LocalChunkStore`,
    # `S3ChunkStore`) as BARE constants, which only works if `Storage` stays on
    # `Module.nesting` — the compact form would drop it, exactly the trap Task 3's own
    # comment on `Sync::Version` describes for `Sync::ManifestChunk`.
    class ChunkStore
      class << self
        attr_writer :current

        def current
          @current ||= build
        end

        def reset!
          @current = nil
        end

        def build
          case ENV.fetch("STORAGE_BACKEND", Rails.env.test? ? "memory" : "s3")
          when "memory" then MemoryChunkStore.new
          when "local"  then LocalChunkStore.from_env
          when "s3"     then S3ChunkStore.from_env
          else raise ArgumentError, "unknown STORAGE_BACKEND"
          end
        end
      end

      # Per-user prefix isolates tenants and bounds the read token's scope.
      def key_for(user_id, hash)
        "chunks/#{user_id}/#{hash}"
      end

      def presign_put(_user_id, _hash, expires_in: 900) = raise(NotImplementedError)
      def presign_get(_user_id, _hash, expires_in: 3600) = raise(NotImplementedError)
      def exists?(_user_id, _hash) = raise(NotImplementedError)

      # SERVER-SIDE write of one chunk. The normal path is a presigned client PUT (bytes never touch
      # Rails, §15); this is the exception for SERVER-GENERATED content (addon output, Maker::Addons::
      # LibraryOutput), where the bytes originate in Rails and there is no client to presign for.
      # Content-addressed, so idempotent.
      def put(_user_id, _hash, _bytes) = raise(NotImplementedError)

      # The storage age (last-modified Time) of a single object, or nil if absent/unsupported.
      # Lets a targeted reaper (Sync::PendingCommitReaper) apply the same grace-window guard the
      # list-based Sync::ChunkReaper gets from `list`, without a full keyspace enumeration. The
      # base returns nil so a backend that can't cheaply stat one object just skips the guard.
      def last_modified(_user_id, _hash) = nil

      # Enumerate the objects under chunks/<user_id>/ — the keyspace a single tenant owns.
      # Returns an array of { hash:, last_modified: } (last_modified a Time). Used by the
      # storage-orphan reaper (Sync::ChunkReaper) to find keys with no DB row. Concrete
      # stores override; the base raises so an enumeration-less backend fails loudly rather
      # than silently reaping nothing. `last_modified` is the object's storage age — the
      # reaper's grace window is measured against it so an in-flight upload isn't reaped.
      def list(_user_id) = raise(NotImplementedError)

      # Delete the object at chunks/<user>/<hash>. The GC sweep calls this AFTER the chunk
      # row is gone, so it MUST be idempotent (tolerate an already-deleted key). The base
      # is a safe no-op so a backend without an admin delete never blocks a sweep.
      def delete(_user_id, _hash) = nil
    end
  end
end
