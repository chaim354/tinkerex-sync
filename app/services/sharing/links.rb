module Sharing
  # Lifecycle for read-only share links (create / redeem / revoke). A redeemed link
  # yields a Capability: a read-only, version-scoped view that can mint presigned GET URLs
  # for exactly that version's manifest chunks — and nothing else the owner happens to own.
  #
  # Why this is safe without re-keying the chunk store (the crux of why this slice is
  # shallow): the bytes stay under the OWNER's keyspace `chunks/<owner_id>/<hash>`, and the
  # presigner is called as `presign_get(owner_id, hash)` only for hashes drawn from THIS
  # version's manifest. The link can never address an arbitrary chunk — the hash set is
  # fixed at create time by the target manifest. Cross-user *write* access (which WOULD need
  # the per-Space keyspace) is out of scope; see docs/plan-sharing.md.
  module Links
    # A read-only capability over one immutable version. Disjoint from device tokens: it is
    # never an authenticated session and cannot be promoted to one.
    class Capability
      attr_reader :owner_id, :node_id, :version_id, :manifest_id, :chunk_hashes

      def initialize(owner_id:, node_id:, version_id:, manifest_id:, chunk_hashes:)
        @owner_id = owner_id
        @node_id = node_id
        @version_id = version_id
        @manifest_id = manifest_id
        @chunk_hashes = chunk_hashes # a Set of hex hashes — the ONLY keys this link can mint
      end

      def can_read?  = true
      def can_write? = false

      # Mint presigned GET URLs for the version's chunks, against the OWNER's keyspace.
      # Bytes still flow client <-> storage directly; Rails only signs the URLs.
      def presign_urls(expires_in: 3600)
        store = Sync::Storage::ChunkStore.current
        @chunk_hashes.to_a.index_with { |h| store.presign_get(@owner_id, h, expires_in:) }
      end
    end

    # Create a link to a specific version of a node owned by `user`. The version's manifest
    # is resolved + frozen into the link (manifest_id), so the link is a stable read-only
    # snapshot even if the file is later overwritten.
    def self.create_for_version!(user:, node_id:, version_id:, expires_at: nil)
      version = user.versions.find_by!(node_id:, version_id:)
      raw = SecureRandom.urlsafe_base64(32)
      link = Sync::ShareLink.create!(
        user:, node_id:, version_id:,
        manifest_id: version.manifest_id,
        token_digest: Sync::ShareLink.digest(raw),
        expires_at:
      )
      link.define_singleton_method(:raw_token) { raw }
      link
    end

    # Redeem a raw token. Returns a Capability if the link exists and is live; nil otherwise
    # (unknown / expired / revoked). The chunk-hash set is read fresh from the (immutable)
    # manifest each redeem, so liveness + scope are always re-evaluated server-side.
    def self.redeem(raw)
      link = Sync::ShareLink.find_by(token_digest: Sync::ShareLink.digest(raw))
      return nil unless link&.live?

      hashes = Sync::ManifestChunk
                 .where(user_id: link.user_id, manifest_id: link.manifest_id)
                 .pluck(:chunk_hash).to_set
      Capability.new(owner_id: link.user_id, node_id: link.node_id,
                     version_id: link.version_id, manifest_id: link.manifest_id,
                     chunk_hashes: hashes)
    end

    def self.revoke!(link)
      link.update!(revoked_at: Time.current)
    end
  end
end
