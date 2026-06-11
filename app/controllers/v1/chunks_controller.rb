module V1
  class ChunksController < BaseController
    # POST /v1/chunks/download { hashes: [...] } -> { urls: { hash => presigned GET } }
    # Hydration: the client requests presigned GETs for the chunks it needs.
    def download
      hashes = Array(params[:hashes]).map(&:to_s)
      store = Storage::ChunkStore.current
      urls = hashes.index_with { |h| store.presign_get(current_user.id, h) }
      render json: { urls: }
    end
  end
end
