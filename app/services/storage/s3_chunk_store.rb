module Storage
  # R2/S3 store. Presigns PUT (upload missing chunks) and GET (hydration). Works with
  # Cloudflare R2 by setting CHUNK_ENDPOINT to the R2 endpoint and CHUNK_REGION=auto.
  #
  # `aws-sdk-s3` is required lazily so the app boots without it (tests use the memory
  # store). For a managed/Postgres deploy, add `gem "aws-sdk-s3"` — see SYNC_SERVER.md.
  class S3ChunkStore < ChunkStore
    def self.from_env
      new(
        bucket:            ENV.fetch("CHUNK_BUCKET"),
        endpoint:          ENV["CHUNK_ENDPOINT"],
        region:            ENV.fetch("CHUNK_REGION", "auto"),
        access_key_id:     ENV.fetch("CHUNK_ACCESS_KEY_ID"),
        secret_access_key: ENV.fetch("CHUNK_SECRET_ACCESS_KEY")
      )
    end

    def initialize(bucket:, region:, access_key_id:, secret_access_key:, endpoint: nil)
      require "aws-sdk-s3"
      @bucket = bucket
      opts = { region:, access_key_id:, secret_access_key:, force_path_style: true }
      opts[:endpoint] = endpoint if endpoint.present?
      @client = Aws::S3::Client.new(**opts)
      @presigner = Aws::S3::Presigner.new(client: @client)
    end

    def presign_put(user_id, hash, expires_in: 900)
      @presigner.presigned_url(:put_object, bucket: @bucket, key: key_for(user_id, hash), expires_in:)
    end

    def presign_get(user_id, hash, expires_in: 3600)
      @presigner.presigned_url(:get_object, bucket: @bucket, key: key_for(user_id, hash), expires_in:)
    end

    def exists?(user_id, hash)
      @client.head_object(bucket: @bucket, key: key_for(user_id, hash))
      true
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      false
    end

    def last_modified(user_id, hash)
      @client.head_object(bucket: @bucket, key: key_for(user_id, hash)).last_modified
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      nil
    end

    # Enumerate chunks/<user_id>/ for the storage-orphan reaper. Paginates list_objects_v2
    # (1000 keys/page) over the per-user prefix; returns { hash:, last_modified: } for each.
    # The hash is the key suffix after the prefix; last_modified is S3's object timestamp,
    # which the reaper measures its grace window against. NOTE: list_objects_v2 is billed
    # per request (~1 req / 1000 objects), so the reaper runs on a conservative schedule.
    def list(user_id)
      prefix = key_for(user_id, "") # "chunks/<user_id>/"
      out = []
      continuation = nil
      loop do
        resp = @client.list_objects_v2(
          bucket: @bucket, prefix:, continuation_token: continuation
        )
        (resp.contents || []).each do |obj|
          hash = obj.key.delete_prefix(prefix)
          next if hash.empty? || hash.include?("/")
          out << { hash:, last_modified: obj.last_modified }
        end
        break unless resp.is_truncated
        continuation = resp.next_continuation_token
      end
      out
    end

    # Free the object. S3/R2 delete_object is idempotent (204 even for a missing key);
    # we also swallow NotFound/NoSuchKey so a re-run after a partial sweep can't raise.
    def delete(user_id, hash)
      @client.delete_object(bucket: @bucket, key: key_for(user_id, hash))
      nil
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      nil
    end
  end
end
