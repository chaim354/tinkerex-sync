module FileLayer
  # The chunk-store adapter: the sync engine's content-addressed store, where a file's bytes
  # are the ordered manifest_chunks of an immutable version. This is the ONLY adapter that
  # can restore history, so its content_token is a version UUID.
  #
  # Runs server-side (preview jobs), so it reads chunks directly rather than via presigned
  # URLs where the store allows it.
  class Chunk
    # One message per op, NOT one shared string: these are three different doors. A shared
    # constant is what made an earlier draft of this class tell delete/move callers to use
    # Sync::Commit, which has no delete or move path at all.
    WRITE_MSG = "chunk-mode writes go through the sync engine (Sync::Commit's two-phase " \
                "commit), not through FileLayer".freeze

    # Sync::SubtreeDelete, NOT Sync::Mutation.apply(op: "delete"): the latter tombstones only
    # the node it is given, so on a directory it orphans the descendants — /v1/tree would serve
    # children pointing at a deleted parent while changelog-following devices dropped the whole
    # subtree (see Sync::SubtreeDelete's header). SubtreeDelete is the safe superset: on a
    # childless file it collects exactly one node and does the identical single tombstone, which
    # is why it is the right answer to give a caller who has not told us which kind they hold.
    DELETE_MSG = "chunk-mode delete goes through the sync engine (Sync::SubtreeDelete.call, " \
                 "which cascades the tombstone to the subtree), not through FileLayer".freeze

    MOVE_MSG = 'chunk-mode move goes through the sync engine (Sync::Mutation.apply, op: "move"), ' \
               "not through FileLayer".freeze

    def capabilities
      # scannable: false — chunk mode's tree comes from the sync engine's changelog, not from
      # anyone walking a store. Library::ScanJob.scan_all! reads this and no-ops here, which is the
      # answer to a question nobody asked: there is no store to poll, and `nodes` is already
      # authoritative.
      #
      # port_writable: false — and this is NOT "chunk mode can't take uploads", which it does
      # all day. It says the port is the wrong door: the UI must drive Sync::Commit's two-phase
      # presigned flow, which is why write/delete/move below refuse. Read as "accepts uploads"
      # it would hide the upload button in the product's main deployment.
      Capabilities.new(versioned: true, syncable: true, presignable: true, scannable: false,
                       port_writable: false, dir_deletable: true)
    end

    def stat(user, node_id:)
      node = live_node!(user, node_id)
      file_info(node, node.current_version&.size)
    end

    # Describe MANY nodes in a number of queries that does not grow with the list — what a browse
    # view actually asks, and what #stat cannot answer without one query per row.
    #
    # A PORT VERB RATHER THAN A LOOP AT THE CALLER, and the evidence that it was missing sits a
    # few lines below: #trashed already hand-rolled this exact two-query shape ("One query, not
    # one per node"), privately, because the port had no way to express it. FilesController#index
    # could not do the same — it holds an ADAPTER, not a Chunk — so it looped #stat and paid a
    # query per row (measured: 4000 queries / 527 ms of the 676 ms page, at 2000 nodes). The next
    # bulk caller would have re-invented #trashed's private query a third time, and three private
    # copies of one question is the divergence the shared contract exists to stop.
    #
    # A MISSING NODE IS AN ABSENT KEY, NOT A RAISE, and that is not laxness: #stat is asked about
    # ONE node the caller named, so "it isn't there" IS its whole answer and NotFound is right. A
    # bulk caller holds a LIST, and one row tombstoned between its query and this one must not
    # take the whole page down — which is exactly what looping #stat did. A Hash reports the same
    # fact by omission and lets the caller decide. Pinned as a cross-backend rule, because an
    # adapter that raised instead would 404 a page on the deployment that happened to race.
    def stat_all(user, node_ids:)
      nodes = user.nodes.present.where(node_id: node_ids).to_a
      # The sizes in ONE query, exactly as #trashed does it. Node#current_version is a `find_by`,
      # not an association (app/models/node.rb), so `includes` cannot reach it and nothing but an
      # explicit pluck collapses the second query per row.
      sizes = user.versions.where(version_id: nodes.filter_map(&:current_version_id))
                  .pluck(:version_id, :size).to_h
      nodes.to_h { |n| [ n.node_id, file_info(n, sizes[n.current_version_id]) ] }
    end

    # What is in this deployment's trash. A READ verb, so every adapter answers it — unlike
    # `undelete`, which is a write and so raises here (chunk-mode restore is Sync::Trash.restore,
    # driven by TrashController's port_writable branch).
    #
    # DELEGATES TO Sync::Trash RATHER THAN RE-ASKING THE QUESTION. `user.nodes.where(deleted:
    # true)` here would be a second definition of "the trash" alongside the one V1::TrashController
    # already serves — §9a-3's complaint exactly, and the two would drift the first time either
    # grew a rule. This adapter is the one place sync-shaped knowledge belongs (it already reads
    # Version, ManifestChunk and Storage::ChunkStore), so it wraps that answer into the port's
    # shape instead of minting a rival one. Nothing in Sync::* changes (spec §10).
    #
    # EVERY tombstone is listed, with no filter, and that is chunk mode's real answer rather than
    # laziness: versions are kept forever (§5), so a tombstoned node's bytes are always one
    # restore away. Share and S3 must filter, because there the bytes are only recoverable if WE
    # moved them to `.trash` — see the argument at Share#trashed.
    def trashed(user)
      nodes = Sync::Trash.list(user:).to_a
      # One query, not one per node: this list is unbounded (it is every file the user ever
      # deleted) and #stat's per-node lookup would be an N+1 across all of it.
      sizes = user.versions.where(version_id: nodes.filter_map(&:current_version_id))
                  .pluck(:version_id, :size).to_h
      nodes.map do |n|
        TrashEntry.new(node_id: n.node_id, name: n.name, kind: n.kind,
                       size: sizes[n.current_version_id], deleted_at: n.updated_at)
      end
    end

    def read(user, node_id:, content_token: nil)
      # A tombstoned node is GONE on every backend (contract:
      # test_contract_read_raises_not_found_for_a_deleted_node). Checked BEFORE resolving the
      # version, and OUTSIDE the branch below, because the by-token path queries `versions` and
      # would otherwise never consult `nodes` at all — leaving the asymmetry inside this very
      # method, on the path every production caller actually uses (contract:
      # test_contract_read_at_a_token_captured_before_deletion_raises_not_found).
      node = live_node!(user, node_id)

      version =
        if content_token.present?
          user.versions.find_by(node_id:, version_id: content_token)
        else
          node.current_version
        end
      raise NotFound, "no version for node #{node_id.inspect}" unless version

      store = Storage::ChunkStore.current
      buf = +"".b
      version.manifest_chunks.each do |mc|
        bytes = self.class.fetch(store, user.id, mc.chunk_hash)
        raise NotFound, "missing chunk #{mc.chunk_hash}" if bytes.nil?
        buf << bytes.b
        raise NotFound, "file exceeds #{MAX_BYTES} bytes" if buf.bytesize > MAX_BYTES
      end
      buf
    end

    # Hand the browser this file's bytes. FilesController#blob's behavior, moved behind the port
    # UNCHANGED — including the single-chunk redirect, which is not an optimization to tidy up
    # but the one place chunk mode keeps §15 for a web download.
    #
    # `disposition:`/`content_type:` are the CONTROLLER'S policy (SAFE_INLINE_TYPES: which types
    # may render inline in our origin, and ?download=1). Chunk's Stream does not apply them —
    # the controller sets those headers itself, exactly as #blob does today — but the port's
    # signature carries them because S3's Redirect must SIGN them into the URL at mint time, and
    # a redirect that dropped them would serve an SVG executable from the bucket's origin while
    # the same button on the same UI attached it here. See Delivery.
    #
    # NOT read's job and not read's rules: `download` never buffers, so MAX_BYTES (a
    # host-protection cap on holding a whole file in memory) does not apply. The enumerator is
    # LAZY — that is what keeps a 2GB file off the Rails heap.
    #
    # `disposition:` is REQUIRED even though this adapter never reads it — the port has ONE
    # signature, and a caller who may omit it here but not on S3 learns the rule from whichever
    # backend they developed against. See S3#download: omitting it there silently mints a signed
    # header with no disposition type, which browsers resolve as inline.
    def download(user, node_id:, disposition:, content_type: nil)
      # The same liveness guard read applies: a tombstoned node is GONE on every backend, and
      # download must not be the hole in that.
      node = live_node!(user, node_id)
      version = node.current_version
      raise NotFound, "no version for node #{node_id.inspect}" unless version

      chunks = version.manifest_chunks.to_a
      store = Storage::ChunkStore.current

      # BOTH HALVES OF THIS CONDITION ARE LOAD-BEARING, and neither is the presignable? question.
      #
      # `is_a?(S3ChunkStore)` — do NOT rewrite this as `capabilities.presignable?`. Verified: all
      # three chunk stores implement presign_get, but the memory and local stores presign to URLs
      # RAILS ITSELF SERVES, so redirecting to one would send the browser on a pointless round
      # trip back through us — the opposite of what the redirect is for. "Can this store presign?"
      # and "does its URL point off-box?" are different questions, and only the second belongs
      # here. §9a-3/§9a-4's cleanup of the presignable/duck-typing split is real and stays
      # deferred; this is why Phase 4 does not force it.
      #
      # `chunks.size == 1` — a redirect can only ever name ONE object. Redirecting a multi-chunk
      # file hands the browser its first chunk with a 200 and the right filename: silent
      # truncation, no error anywhere.
      if chunks.size == 1 && store.is_a?(Storage::S3ChunkStore)
        return Delivery::Redirect.new(url: store.presign_get(user.id, chunks.first.chunk_hash))
      end

      Delivery::Stream.new(enum: Enumerator.new do |y|
        chunks.each do |mc|
          bytes = self.class.fetch(store, user.id, mc.chunk_hash)
          # nil is "genuinely absent" (a 404 from the presigned GET) — the same terminal answer
          # read gives it. #blob used `|| ""` for the memory store, which silently served a file
          # with a hole in it; the enumerator raising is loud, and by here the response has
          # already begun, so quiet corruption is the one outcome worth refusing.
          raise NotFound, "missing chunk #{mc.chunk_hash}" if bytes.nil?
          y << bytes
        end
      end)
    end

    # The port's write path is share/s3 only. Chunk-mode mutations are the sync engine's, and
    # each has its own door (see the constants above). Implementing them here would mean a
    # server-side chunk-and-commit path that duplicates Sync::Commit, has no caller, and
    # reaches into the sync engine this port exists to stay out of (spec §10).
    #
    # They exist, rather than being absent, so the answer is an honest error instead of a
    # NoMethodError that reads as an oversight — which only holds if each error names the door
    # that op actually uses. A confident wrong answer is worse than NoMethodError: NoMethodError
    # sends you to the code, a wrong class name sends you to the wrong file.
    #
    # The keyword names are the port's intended shape and are documentary: a reader sees exactly
    # which call is being refused. The defaults are deliberate too — a caller who omits one gets
    # this explanation rather than an ArgumentError about a missing keyword, which would hide the
    # real answer.
    def write(_user, parent_node_id: nil, name: nil, io: nil)
      raise NotImplementedError, WRITE_MSG
    end

    def delete(_user, node_id: nil)
      raise NotImplementedError, DELETE_MSG
    end

    def move(_user, node_id: nil, new_parent_node_id: nil, new_name: nil)
      raise NotImplementedError, MOVE_MSG
    end

    # THE PORT IS THE DOOR, and it was a refusal until Stage 2. It changed because
    # Maker::LibraryFolder used to branch around the port into Sync::Mutation directly -- which
    # works only while the sync engine is in this process. It will not be.
    #
    # IDEMPOTENT, matching Share#mkdir: Maker::LibraryFolder walks a path segment by segment and
    # calls this for each one, so a second walk of an existing path must return the SAME node.
    # Returning a fresh one would mint a duplicate directory on every ensure_path! of a path that
    # already exists -- which is the common case, not the edge case.
    def mkdir(user, parent_node_id: nil, name: nil)
      existing = user.nodes.present.find_by(parent_node_id:, name:, kind: "dir")
      return file_info(existing, nil) if existing

      node = user.nodes.new(
        node_id: SecureRandom.uuid, parent_node_id:, name:, kind: "dir",
        deleted: false, mode: 0o755, mtime: (Time.current.to_f * 1e9).to_i
      )
      seq = Sync::Mutation.apply(user:, node:, op: "mkdir")
      LibraryChannel.broadcast_change(user, seq)
      file_info(node, nil)
    end

    # Normalize over the chunk-store backends.
    #   - memory store exposes read_blob (tests/dev)
    #   - local filesystem store exposes read
    #   - S3 store exposes presign_get -> pull the bytes over the presigned GET
    #
    # Returns the bytes, or nil ONLY when the chunk is genuinely absent (a 404 from the
    # presigned GET). A non-404 HTTP error (403 auth, 5xx) or a network error is a TRANSIENT
    # failure -> raise FetchError so the caller retries instead of treating it as permanently
    # missing.
    def self.fetch(store, user_id, hash)
      if store.respond_to?(:read_blob)
        store.read_blob(user_id, hash)
      elsif store.respond_to?(:read)
        store.read(user_id, hash)
      else
        http_get(store.presign_get(user_id, hash))
      end
    rescue OpenURI::HTTPError => e
      # io.status is ["404", "Not Found"]; 404 means the object isn't there (terminal, nil ->
      # NotFound upstream). Anything else (403/5xx) is transient -> FetchError.
      status = e.io.status.first.to_i rescue 0
      return nil if status == 404
      raise FetchError, "chunk GET #{hash}: HTTP #{status} (#{e.message})"
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout,
           Net::ReadTimeout, Timeout::Error => e
      raise FetchError, "chunk GET #{hash}: #{e.class} (#{e.message})"
    end

    # The HTTP fetch seam (presigned GET -> bytes). Extracted so it can be exercised/faulted
    # in isolation; the edge tests stub THIS method. open-uri raises OpenURI::HTTPError for
    # non-2xx, carrying the status.
    def self.http_get(url)
      require "open-uri"
      require "net/http"
      URI.parse(url).open(&:read)
    end

    # NOTE: only affects the instance methods below; `def self.` methods above stay public.
    private

    # The liveness guard both stat and read must apply. Shared rather than duplicated because
    # stat and read answering DIFFERENTLY for the same node is precisely the bug this closes
    # (§9a-1) — one copy means they cannot drift apart again.
    #
    # The message avoids internal jargon and does not distinguish deleted from never-existed:
    # it reaches end users through preview.error (rendered into the previews API JSON), and to
    # a caller holding a node_id the two states are the same answer — the file isn't there.
    def live_node!(user, node_id)
      user.nodes.present.find_by(node_id:) ||
        raise(NotFound, "node #{node_id.inspect} is deleted or does not exist")
    end

    # The one place a node becomes a FileInfo, shared by stat and stat_all for the reason
    # live_node! is shared: the browse view (stat_all) and the detail view (stat) describing the
    # same file DIFFERENTLY is precisely the §9a-1 bug in a new spelling, and one copy is what
    # makes it impossible rather than merely unlikely.
    #
    # `size` is passed IN rather than read off the node, because that is the only part the two
    # callers resolve differently — one version lookup vs. one plucked batch — and it is exactly
    # the part the N+1 was made of. `.to_i` maps a version-less node (or a current_version_id
    # whose row is gone) to 0 on both paths, which is what stat has always answered.
    def file_info(node, size)
      FileInfo.new(
        node_id: node.node_id,
        name: node.name,
        kind: node.kind,
        size: size.to_i,
        mtime: node.mtime,
        content_token: node.current_version_id
      )
    end
  end
end
