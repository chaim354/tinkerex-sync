module Sync
  module V1
    class ChunksController < BaseController
      # STAGE 3a TASK 5: this presigns a GET, so it needs the same LocalChunkStore base-url stash
      # V1::CommitsController does (both used to get it for free from V1::BaseController). See
      # app/controllers/concerns/v1/stash_request_base_url.rb for the full argument. Explicitly
      # qualified `::V1::` -- that file stays HOST (see Sync::V1::CommitsController's comment and
      # Sync::V1::BaseController's header for why).
      include ::V1::StashRequestBaseUrl

      # Hydration presigns CHUNKS, which only a chunk-mode library has -- so the gate is `syncable`
      # and emphatically NOT `presignable`. S3 answers presignable: TRUE (that is the whole point of
      # FileLayer::S3::Redirect) while having no chunk to hydrate, so gating on presignable here
      # would leave this endpoint open on s3, minting nothing and explaining nothing.
      require_capability! :syncable

      # POST /v1/chunks/download { hashes: [...] } -> { urls: { hash => presigned GET } }
      # Hydration: the client requests presigned GETs for the chunks it needs.
      #
      # Defense in depth: only presign chunks this user actually owns (has a chunk record
      # for). The key is already user-scoped (chunks/<user_id>/<hash>, SigV4-signed so it
      # can't be retargeted) — cross-user access is impossible regardless — but this also
      # refuses to mint URLs for hashes the user doesn't reference, so a token can't fish
      # for arbitrary keys.
      # Cap the batch size so a single request can't ask us to mint (and DB-lookup) an
      # unbounded number of URLs — a memory/DB DoS, mirroring the tree/changes pagination caps.
      MAX_DOWNLOAD_HASHES = 10_000

      def download
        hashes = Array(params[:hashes]).map(&:to_s).uniq
        if hashes.size > MAX_DOWNLOAD_HASHES
          render json: { error: "too many hashes (#{hashes.size} > #{MAX_DOWNLOAD_HASHES})" },
                 status: :unprocessable_entity
          return
        end
        # Only ever presign a well-formed hash (64-hex SHA-256). A malformed hash could never
        # be `owned` (DB hashes are all valid), but validating here refuses to even build a
        # storage key from client-controlled junk — defense in depth against a path-traversal
        # key on a path-based S3 gateway.
        hashes = hashes.select { |h| Sync::Commit::HASH_RE.match?(h) }
        owned = current_user.chunks.where(chunk_hash: hashes).pluck(:chunk_hash).to_set
        store = Sync::Storage::ChunkStore.current
        urls = hashes.index_with { |h| owned.include?(h) ? store.presign_get(current_user.id, h) : nil }.compact
        render json: { urls: }
      end
    end
  end
end
