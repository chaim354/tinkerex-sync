module V1
  module Chunks
    # The storage tier for the `local` (filesystem) chunk backend — the colocated stand-in for
    # S3/R2's data plane. These endpoints take chunk BYTES (PUT to upload, GET to hydrate), so
    # they're the ONLY place bytes touch Rails — and only for the self-hosted single-box `local`
    # backend (production uses S3/R2, where bytes go straight to object storage and never reach
    # Rails). NOT under BaseController: there's no bearer token — authorization is the **HMAC sig**
    # in the URL (presigned by LocalChunkStore, keyed by user_id+hash+expiry with the Rails
    # secret), exactly mirroring how a presigned S3 URL carries its own auth. A tampered or expired
    # URL is rejected; the key is user-scoped so cross-user access is impossible (CLAUDE.md §8).
    class BlobController < ActionController::API
      MAX_BYTES = 64 * 1024 * 1024 # generous per-chunk cap (FastCDC chunks are KBs)

      before_action :ensure_local_backend
      before_action :verify_signature

      # PUT /v1/chunks/blob/:user_id/:hash?exp&sig — store the uploaded chunk bytes.
      def upload
        bytes = request.body.read(MAX_BYTES + 1)
        bytes = bytes.to_s.dup.force_encoding(Encoding::BINARY)
        return render(plain: "chunk too large", status: :payload_too_large) if bytes.bytesize > MAX_BYTES
        store.write(params[:user_id], params[:hash], bytes)
        head :ok
      end

      # GET /v1/chunks/blob/:user_id/:hash?exp&sig — return the chunk bytes (hydration).
      def download
        bytes = store.read(params[:user_id], params[:hash])
        return head(:not_found) if bytes.nil?
        send_data bytes, type: "application/octet-stream", disposition: "inline"
      end

      private

      def store
        @store ||= Storage::ChunkStore.current
      end

      def ensure_local_backend
        head(:not_found) unless store.is_a?(Storage::LocalChunkStore)
      end

      def verify_signature
        ok = Storage::LocalChunkStore.verify(params[:user_id], params[:hash], params[:exp], params[:sig])
        head(:forbidden) unless ok
      end
    end
  end
end
