module V1
  class ChunksController < BaseController
    # POST /v1/chunks/download { hashes: [...] } -> { urls: { hash => presigned GET } }
    # Hydration: the client requests presigned GETs for the chunks it needs.
    #
    # Defense in depth: only presign chunks this user actually owns (has a chunk record
    # for). The key is already user-scoped (chunks/<user_id>/<hash>, SigV4-signed so it
    # can't be retargeted) — cross-user access is impossible regardless — but this also
    # refuses to mint URLs for hashes the user doesn't reference, so a token can't fish
    # for arbitrary keys.
    def download
      hashes = Array(params[:hashes]).map(&:to_s).uniq
      owned = current_user.chunks.where(chunk_hash: hashes).pluck(:chunk_hash).to_set
      store = Storage::ChunkStore.current
      urls = hashes.index_with { |h| owned.include?(h) ? store.presign_get(current_user.id, h) : nil }.compact
      render json: { urls: }
    end
  end
end
