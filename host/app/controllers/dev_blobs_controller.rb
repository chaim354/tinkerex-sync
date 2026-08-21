# A SECOND GENUINE FINDING, independent of the HOST_MODELS/HOST_CONSTANTS gaps: this file has NO
# host equivalent it merely copies short of the real app's OWN dev_blobs_controller.rb (which
# this mirrors closely) -- but it exists precisely BECAUSE Sync::Storage::MemoryChunkStore
# (engines/tinkerex-sync/app/services/sync/storage/memory_chunk_store.rb) presigns to a bare path
# string, "/dev/blobs/#{key_for(user_id, hash)}", with no host constant reference at all (verified:
# ArchitectureInvariantsTest's host-constant scan reports it clean). That cleanliness is exactly
# the trap -- the coupling is not in the CODE, it is in the ROUTING: nothing under
# engines/tinkerex-sync/app ever serves that path, so a bare mount whose MemoryChunkStore hands a
# client a presigned PUT/GET URL is handing out a URL that 404s unless SOMETHING routes
# "/dev/blobs/*key" to code that reads/writes ChunkStore.current's blob_key methods. On the real
# host that something is app/controllers/dev_blobs_controller.rb + a route in config/routes.rb;
# this dummy needs its own copy for the same reason it needs its own User/Node/Device -- and this
# one the engine's own HOST_MODELS list never named at all, because it is not a model the engine
# asks for, it is dev/test plumbing the STORE'S OWN presigned URLs silently assume exists.
#
# Byte-identical to the host's app/controllers/dev_blobs_controller.rb.
class DevBlobsController < ActionController::Base
  skip_forgery_protection # presigned-style PUT from a raw client; not a form post

  before_action :ensure_memory_store

  # PUT /dev/blobs/*key — store the raw chunk bytes (the "presigned PUT").
  def update
    bytes = request.body.read
    bytes = request.raw_post if bytes.nil? || bytes.empty?
    @store.write_blob_key(params[:key], bytes.to_s)
    head :ok
  end

  # GET /dev/blobs/*key — return the raw chunk bytes (the "presigned GET").
  def show
    data = @store.read_blob_key(params[:key])
    return head(:not_found) if data.nil?
    send_data data, type: "application/octet-stream", disposition: "inline"
  end

  private

  def ensure_memory_store
    @store = Sync::Storage::ChunkStore.current
    head :not_found unless @store.is_a?(Sync::Storage::MemoryChunkStore)
  end
end
