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
  end
end
