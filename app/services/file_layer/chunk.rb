module FileLayer
  # THE ONE FILE IN app/services/file_layer/ THAT LIVES IN THE ENGINE, NOT THE HOST -- Stage 3b
  # Phase B Task 7. Everything else under FileLayer:: (the factory in app/services/file_layer.rb,
  # Share, S3, Capabilities, Delivery, the shared error classes) stays host: FileLayer IS the
  # maker layer's port abstraction, and Share/S3 are host-owned storage adapters with nothing
  # engine-shaped about them. This one class is the exception, because it is not really a NEW
  # adapter so much as a THIN WRAPPER: every method here delegates straight into Sync::Commit,
  # Sync::Mutation, Sync::SubtreeDelete, Sync::Storage::ChunkStore -- engine services this file
  # exists only to expose through the port's vocabulary (CLAUDE.md §14a).
  #
  # STILL `FileLayer::Chunk`, NOT `Sync::FileLayer::Chunk` -- deliberately kept in the HOST'S
  # namespace despite living in the engine's own directory tree. `FileLayer` is not pre-defined
  # the way `Sync` is (no isolate_namespace analog forces it), so Zeitwerk autovivifies it
  # normally the first time anything references it, from WHICHEVER root gets there first, and
  # is fine having two physical roots (this engine's app/services/file_layer/ and the host's)
  # both contribute files under that one logical namespace -- confirmed with a bare
  # Zeitwerk::Loader probe (two push_dir calls, two roots, a bare sibling-namespace constant
  # lookup across the root boundary) before this file moved for real. Renaming it to
  # `Sync::FileLayer::Chunk` would break every caller (FileLayer.build's `Chunk.new`,
  # `rescue_from FileLayer::UnsupportedOperation` in the maker controllers) for a rename that
  # buys nothing -- this class's whole reason to exist is being reachable AS a FileLayer adapter.
  #
  # The chunk-store adapter: the sync engine's content-addressed store, where a file's bytes
  # are the ordered manifest_chunks of an immutable version. This is the ONLY adapter that
  # can restore history, so its content_token is a version UUID.
  #
  # Runs server-side (preview jobs), so it reads chunks directly rather than via presigned
  # URLs where the store allows it.
  class Chunk
    # ITS OWN MESSAGE, NOT A STRING SHARED WITH ANOTHER REFUSAL: an earlier draft of this class
    # shared one constant across write AND delete, which told delete callers to use Sync::Commit --
    # a door that has no delete path at all. Delete no longer refuses (Stage 2 moved it onto the
    # port, below, same as mkdir and move before it), so this is the one refusal left here -- but
    # the lesson is the reason to keep it a named, per-op constant rather than an inline string if
    # this class ever grows another one.
    # AND ITS TEXT WAS WRONG THE MOMENT begin_upload/finalize_upload LANDED. It used to end
    # "...not through FileLayer", which was true while chunk uploads bypassed the port entirely.
    # They no longer do -- they go through the two port verbs defined below, in this same class --
    # so the old wording sent a reader hitting this refusal straight at the Sync::Commit bypass
    # this whole arc exists to close, which is the one move §14d's tripwire says never to make.
    # What is refused is the BYTE-TAKING write, and only that: it would move bytes through Rails,
    # which §15 forbids. Naming the door that IS right is the entire job of this message.
    WRITE_MSG = "chunk-mode writes take no IO: bytes go browser-to-storage over the presigned " \
                "URLs FileLayer#begin_upload hands out, then FileLayer#finalize_upload records " \
                "the version (Sync::Commit's two-phase commit, underneath the port)".freeze

    def capabilities
      # scannable: false — chunk mode's tree comes from the sync engine's changelog, not from
      # anyone walking a store. Library::ScanJob.scan_all! reads this and no-ops here, which is the
      # answer to a question nobody asked: there is no store to poll, and `nodes` is already
      # authoritative.
      #
      # port_writable: false — and this is NOT "chunk mode can't take uploads", which it does
      # all day. It says the port is the wrong door for BYTES: the UI must drive Sync::Commit's
      # two-phase presigned flow, which is why write below refuses. Read as "accepts uploads" it
      # would hide the upload button in the product's main deployment. mkdir, move, delete and
      # undelete are METADATA verbs, not bytes, so this capability does not gate them -- all four
      # now go through the port on every backend regardless of what this flag says (CLAUDE.md 14a:
      # port_writable answers which upload flow the UI drives, not "does this op work").
      Capabilities.new(versioned: true, syncable: true, presignable: true, scannable: false,
                       port_writable: false, dir_deletable: true)
    end

    def stat(user, node_id:)
      node = live_node!(user, node_id)
      file_info(node, current_version_for(user, node)&.size)
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
    # Version, ManifestChunk and Sync::Storage::ChunkStore), so it wraps that answer into the port's
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
          current_version_for(user, node)
        end
      raise NotFound, "no version for node #{node_id.inspect}" unless version

      store = Sync::Storage::ChunkStore.current
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
      version = current_version_for(user, node)
      raise NotFound, "no version for node #{node_id.inspect}" unless version

      chunks = version.manifest_chunks.to_a
      store = Sync::Storage::ChunkStore.current

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
      if chunks.size == 1 && store.is_a?(Sync::Storage::S3ChunkStore)
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

    # The port's write path is share/s3 only. Chunk-mode WRITES are the sync engine's own --
    # Sync::Commit's two-phase presigned flow -- and this is that door's honest refusal rather
    # than an absent method: implementing write here would mean a server-side chunk-and-commit
    # path that duplicates Sync::Commit, has no caller, and reaches into the sync engine this
    # port exists to stay out of (spec §10). mkdir/move/delete/undelete below are METADATA verbs,
    # not bytes, so none of that argument binds them -- they go through the port on every backend,
    # chunk included (see each one's own comment for its history).
    #
    # It exists, rather than being absent, so the answer is an honest error instead of a
    # NoMethodError that reads as an oversight — which only holds if the error names the door
    # write actually uses. A confident wrong answer is worse than NoMethodError: NoMethodError
    # sends you to the code, a wrong class name sends you to the wrong file.
    #
    # The keyword names are the port's intended shape and are documentary: a reader sees exactly
    # which call is being refused. The defaults are deliberate too — a caller who omits one gets
    # this explanation rather than an ArgumentError about a missing keyword, which would hide the
    # real answer.
    def write(_user, parent_node_id: nil, name: nil, io: nil)
      raise NotImplementedError, WRITE_MSG
    end

    # --- Upload: phase 1 (begin) ---------------------------------------------------------------
    #
    # THE LAST TWO MAKER-LAYER CALL SITES THAT NAMED Sync:: DIRECTLY (Task 8) — begin_upload and
    # finalize_upload below lift Sync::Commit's presigned two-phase flow onto the port, closing
    # FilesController#begin_upload/#finalize_upload and
    # Maker::Addons::LibraryOutput#write_chunk's own Sync::Commit calls. THIS IS NOT A BYTE-TAKING
    # WRITE AND MUST NEVER BECOME ONE — `write` above still refuses for exactly the reason it always
    # did. `begin_upload` hands back presigned PUT urls for whichever chunks storage is missing;
    # the CALLER puts bytes there (a browser fetch(), or — for LibraryOutput, which generates the
    # bytes server-side and has no client to presign for — a direct Sync::Storage::ChunkStore#put, kept
    # OUTSIDE this method and outside this class entirely; see LibraryOutput#write_chunk's own
    # comment for why that call was not folded in here). Either way this method's own body never
    # reads or holds a byte. That is what keeps CLAUDE.md 15 true here.
    #
    # `node_id:` IS OPTIONAL, UNLIKE Sync::Commit.begin'S OWN SIGNATURE, WHERE IT IS REQUIRED —
    # because "does this upload create a new file, or become a new version of a specific existing
    # one" is a decision only the CALLER can make, and the two callers disagree: FilesController's
    # browser flow always wants a brand-new file (it never passes one); LibraryOutput's `replace:
    # true` flow wants a SPECIFIC existing node_id, chosen by its own #existing_at lookup. Minting
    # one here for the common "new file" case removes a SecureRandom call from both callers rather
    # than asking each to repeat it; passing one explicitly for the reuse case is unchanged from
    # what LibraryOutput already computed before this task.
    #
    # `commit_id` IS NOT A PARAMETER AT ALL, UNLIKE node_id — neither existing caller has ever
    # reused one across retries (each mints a fresh id per call, always), so unlike node_id there
    # is no caller decision here for the port to defer to. Minting it internally is a pure
    # simplification, not a behaviour choice.
    #
    # RE-RAISES Sync::Commit::InvalidManifest AS THE PORT'S OWN FileLayer::UnsupportedOperation,
    # message preserved verbatim — not a new port-level class. A manifest with a malformed chunk
    # hash or over MAX_MANIFEST_CHUNKS is a CLIENT condition, knowable only by reading THIS
    # request, no Capabilities flag could have gated it in advance, and a different request (a
    # valid manifest) would succeed — UnsupportedOperation's own stated axis (see its comment in
    # file_layer.rb, which now names this as the third instance). Reusing it means
    # FilesController's EXISTING class-level `rescue_from FileLayer::UnsupportedOperation` handles
    # this case unchanged — same 422, same `{ error: e.message }` body — so closing this seam
    # needed no new controller rescue at all, only deleting the redundant per-action one.
    def begin_upload(user, name:, size:, manifest:, device:, parent_node_id: nil,
                     node_id: nil, base_version_id: nil, mtime: nil, mode: nil)
      node_id ||= SecureRandom.uuid
      result = Sync::Commit.begin(
        user:, device:, commit_id: SecureRandom.uuid, node_id:, parent_node_id:, name:,
        base_version_id:, size:, mtime:, manifest:, mode:
      )
      UploadBegun.new(commit_id: result.commit_id, node_id:, put_urls: result.put_urls,
                      missing: result.missing)
    rescue Sync::Commit::InvalidManifest => e
      raise UnsupportedOperation, e.message
    end

    # --- Upload: phase 2 (finalize) ------------------------------------------------------------
    #
    # `verify:` DEFAULTS true — the SAFER of the two callers' existing choices, so a caller that
    # forgets to think about it gets the confirm-the-bytes-landed check rather than silently
    # skipping it. FilesController passes it explicitly anyway (a browser's PUT can genuinely fail
    # or be skipped between the two phases, so confirming matters there); LibraryOutput passes
    # false explicitly, UNCHANGED from before this task — it just wrote the bytes itself,
    # synchronously, earlier in this same method call, so re-verifying would be a wasted storage
    # round-trip confirming something nothing between the two calls could have altered.
    #
    # RE-RAISES Sync::Commit::ChunksMissing AS FileLayer::ChunksMissing, hashes preserved — unlike
    # InvalidManifest above, no EXISTING FileLayer class carries structured data the way this one
    # must (both callers that handle it read `.hashes` back out to tell the truth about which
    # chunks to retry), so this genuinely needs a new member of the closed vocabulary rather than a
    # reuse. See its definition in file_layer.rb.
    #
    # DOES NOT CATCH Sync::Commit::KindConflict, DELIBERATELY — neither existing caller of this
    # method can ever trigger it. It fires only when `pending.node_id` already exists as a
    # non-file, and both callers' node_ids are either freshly minted by #begin_upload above (a
    # SecureRandom UUID colliding with any existing node is not a real possibility) or reused from
    # LibraryOutput's own #existing_at, which is scoped `kind: "file"` — so a reused node_id is
    # already guaranteed to be a file. Leaving it un-rescued preserves today's behaviour exactly
    # (FilesController has never rescued it either), and a future caller that CAN legitimately hit
    # it — passing an arbitrary caller-chosen node_id — should add its own mapping rather than
    # inherit one written for a case that cannot occur here. V1::CommitsController, which genuinely
    # can hit this (a device may reuse a node_id across syncs), maps it directly and is outside
    # this port entirely (SYNC_SIDE_GLOBS).
    #
    # DOES NOT BROADCAST, UNLIKE mkdir/move/delete/undelete ABOVE — deliberately, and this is the
    # one place this class departs from its own "the port owns the changelog nudge" pattern. Each
    # of those four verbs has exactly one caller wanting exactly one behaviour; this one has TWO
    # callers with DIFFERENT EXISTING behaviour for the same fact — FilesController broadcasts (a
    # browser upload should nudge the user's other open tabs/devices), Maker::Addons::LibraryOutput
    # never has (an addon-generated save has never notified live devices of the new file — recorded
    # here, not fixed: whether it SHOULD is a real question, just not this task's to answer).
    # Folding the broadcast in here would silently START broadcasting addon saves, a genuine
    # user-visible behaviour change; instead `seq` rides back out on UploadFinalized and each
    # caller keeps deciding for itself, exactly as it did when calling Sync::Commit.finalize
    # directly. Mutation-checked below (chunk_test.rb): this method broadcasting nothing is the
    # asserted behaviour, not an oversight a future editor should "fix" by adding one.
    # `broadcast:` DEFAULTS TO TRUE, AND THE DEFAULT IS THE WHOLE POINT. mkdir/move/delete/undelete
    # broadcast unconditionally, so forgetting is structurally impossible for them; an earlier
    # draft of this method delegated the nudge to its callers instead, on the grounds that the two
    # it has today happen to want different things. That is exactly the "N doors that must all
    # agree" shape §14f names as this repo's recorded failure pattern -- a third caller would
    # simply forget, nothing would go red, and a device would silently never hear about the
    # commit. Safe-by-default with ONE explicit opt-out is the same behaviour and a better floor.
    #
    # Maker::Addons::LibraryOutput passes false, preserving what addon saves have always done
    # (never nudged; they rely on the periodic sync). That asymmetry is pre-existing and is NOT
    # fixed here -- turning it on would start notifying every device of every addon save, a real
    # user-visible change that does not belong in a refactor.
    def finalize_upload(user, commit_id:, verify: true, broadcast: true)
      version, seq = Sync::Commit.finalize(user:, commit_id:, verify:)
      Sync::LibraryChannel.broadcast_change(user, seq) if broadcast && seq
      node = user.nodes.find_by(node_id: version.node_id)
      UploadFinalized.new(version_id: version.version_id, seq:,
                          info: node ? file_info(node, current_version_for(user, node)&.size) : nil)
    rescue Sync::Commit::ChunksMissing => e
      raise ChunksMissing, e.hashes
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

      # CROSS-KIND, ON PURPOSE -- the same-kind lookup just above is scoped `kind: "dir"`, so it
      # is BLIND to a live FILE already at this exact (parent_node_id, name). Share and S3 both
      # refuse this collision on their own doors (Share#mkdir's `dest.exist? &&
      # !dest.directory?`; S3#mkdir's `destination_vacant!`), and without the matching refusal
      # here, chunk mode would silently mint a dir node ALONGSIDE the file node -- two live nodes
      # sharing one (parent_node_id, name), which no real filesystem can represent as a single
      # directory entry. Every mount (FUSE/CfAPI/WebDAV) eventually hits that as an
      # unrepresentable collision. This is CLAUDE.md 14a's one-condition-two-answers shape: "the
      # destination is taken" must mean the same thing behind every LIBRARY_BACKEND, not just on
      # two of three -- and it is reachable through the ordinary New Folder chooser
      # (Maker::LibraryFolder.create_child!), not merely a hypothetical.
      destination_vacant!(user, parent_node_id, name)

      node = user.nodes.new(
        node_id: SecureRandom.uuid, parent_node_id:, name:, kind: "dir",
        deleted: false, mode: 0o755, mtime: (Time.current.to_f * 1e9).to_i
      )
      seq = Sync::Mutation.apply(user:, node:, op: "mkdir")
      Sync::LibraryChannel.broadcast_change(user, seq)
      file_info(node, nil)
    end

    # RETURNS THE POST-MOVE FileInfo, which is the port's contract and was the one real
    # behavioural difference between the two doors Maker::MoveNode used to pick between: the port
    # resolved the node_id into its OWN instance, so the caller's object still held the pre-move
    # name, while the chunk door assigned the caller's object in place. A caller rendering
    # `node.name` after a rename printed the OLD name on share/s3 only. One door, one answer.
    def move(user, node_id: nil, new_parent_node_id: nil, new_name: nil)
      node = live_node!(user, node_id)

      # THE CLOBBER REFUSAL, MATCHING mkdir'S ABOVE -- Sync::Mutation performs no name check at
      # all, so without this, chunk would silently produce two live nodes sharing one
      # (parent_node_id, name), exactly the collision mkdir's own refusal exists to prevent. Share
      # and S3 both already refuse a move onto a taken name (Share#move's `File.exist?(dest)`;
      # S3#move's `destination_vacant!`) -- CLAUDE.md 14a: "a clobber is UnsupportedOperation, and
      # ALL THREE VERBS moved together". EXCLUDES the node being moved ITSELF, or a no-op move
      # (same folder, same name) would collide with its own destination -- the exact case
      # Maker::MoveNode.collision?'s except_node_id: parameter exists for on the web side,
      # mirrored here so the port agrees with its own caller.
      #
      # THIS DOES NOT CLOSE CLAUDE.md 14c's RECORDED GAP. The port now answers "the destination
      # is taken" the same way on every backend, but the sync engine's own doors are untouched:
      # Sync::Commit still validates a manifest exhaustively and the name not at all, so a device
      # push through the mount can still land a duplicate sibling on chunk. 14c is the right
      # citation, not 12 item 11 -- that one is about a project-scoped upload's dedup being
      # per-folder rather than project-wide, a different gap one layer up.
      destination_vacant!(user, new_parent_node_id, new_name, except_node_id: node.node_id)

      seq = Sync::Mutation.apply(user:, node:, op: "move") do |n|
        n.parent_node_id = new_parent_node_id
        n.name = new_name
      end
      Sync::LibraryChannel.broadcast_change(user, seq)
      file_info(node, current_version_for(user, node)&.size)
    end

    # Sync::SubtreeDelete, NOT Sync::Mutation.apply(op: "delete"): the latter tombstones only the
    # node it is given, so on a directory it orphans the descendants -- /v1/tree would serve
    # children pointing at a deleted parent while changelog-following devices dropped the whole
    # subtree. SubtreeDelete is the safe superset: on a childless file it collects exactly one node
    # and does the identical single tombstone, which is why it is the right answer to give a caller
    # who has not told us which kind they hold.
    #
    # THIS IS WHY CHUNK ANSWERS dir_deletable TRUE while share and s3 answer false. Do not "fix"
    # that asymmetry in either direction: the cascade is real here and impossible there.
    #
    # RETURNS nil, MATCHING Share#delete AND S3#delete -- neither port sibling hands anything back
    # for this verb (both end `node.update!(...)` then a bare `nil`), so this is the port's real
    # contract for delete, not a guess: FilesController#destroy never reads delete's return value
    # on any backend.
    def delete(user, node_id: nil)
      node = live_node!(user, node_id)
      seq = Sync::SubtreeDelete.call(user:, node:)
      Sync::LibraryChannel.broadcast_change(user, seq)
      nil
    end

    # THE FOURTH AND LAST METADATA VERB (Task 6) -- the port is now the door for chunk-mode
    # undelete too. TrashController used to branch on port_writable? and call Sync::Trash.restore
    # directly for the chunk leg; it no longer can, same reason mkdir/move/delete's own comments
    # give -- in remote mode there is no Sync::Trash in this process to branch into.
    #
    # `to_root: true`, MATCHING WHAT TrashController#restore HAS ALWAYS PASSED ON THE CHUNK
    # BRANCH. An ORPHAN -- a node whose parent is itself tombstoned -- has no path to restore
    # under, so Sync::Trash puts it at the root instead of raising ParentDeleted at a user who
    # only clicked Restore.
    #
    # V1::TrashController KEEPS ITS OWN DIRECT Sync::Trash.restore CALL, WITH A CALLER-SUPPLIED
    # to_root: -- do not collapse that one too. It is sync-engine code moving to the sync repo in
    # Stage 3, and the device API genuinely offers the choice this web door does not: a client can
    # ask for the strict answer (409 parent_deleted) and prompt its own user, where a browser
    # Restore click has no such UI and would rather succeed at the root than 500.
    #
    # RESTORE ORDER IS NOT COMMUTATIVE, AND TASK 5'S CASCADE MADE THAT MAINLINE RATHER THAN A RARE
    # HAND-CRAFTED EDGE CASE. Sync::Trash.restore(to_root: true) NULLS parent_node_id when the
    # parent is tombstoned, and a directory delete now tombstones its whole subtree in one call
    # (Sync::SubtreeDelete) -- so restoring a CHILD before its PARENT permanently rewrites that
    # pointer. Restoring the parent AFTERWARD does not reunite them: the child's parent_node_id is
    # already nil, and reviving the parent touches nothing the child still points at. Before
    # delete cascaded, reaching this took two DELIBERATE deletes; now one folder delete is enough,
    # so a bottom-up restore scatters that folder's contents to the root, irreversibly. NOT FIXED
    # HERE: top-down restore (parent, then children) already preserves structure, and ordering the
    # restores is a caller's job, not this adapter's -- see the non-commutativity test for the
    # pinned behaviour.
    #
    # THE COLLISION HOLE STAYS OPEN, DELIBERATELY. Sync::Trash.restore has no
    # destination_vacant!-style check anywhere in it, so on chunk a revive CAN produce two live
    # nodes sharing one (parent_node_id, name) -- share and s3 both refuse that clobber inside
    # their own #undelete (Share's `dest.exist?`; S3's own destination_vacant!). Pre-existing, not
    # introduced by this move behind the port -- the same hole existed when TrashController called
    # Sync::Trash.restore directly. Closing it changes sync-engine semantics the device API
    # (V1::TrashController) also depends on, which is its own decision, not a rider on a refactor
    # that is only supposed to change WHERE a call is made.
    #
    # THE `if seq` GUARD IS NOT PADDING. Sync::Trash.restore returns [node, nil] when the named
    # node is not actually deleted (an early return -- no mutation, no changelog entry), and
    # broadcasting THAT would tell every device to pull for a change that never happened.
    #
    # RETURNS A FileInfo, NOT delete's nil -- and that is not a stylistic choice, it is delete's
    # WRONG precedent for this verb. delete changes no field FileInfo exposes, so its nil costs
    # nothing; undelete can silently reparent a node to the root (see above), and
    # TrashController#restore's flash message reads info.name straight off this return value.
    # TWO DIVERGENCES FROM share/s3 LIVE ON THIS METHOD, AND ONLY ONE OF THEM IS FIXABLE HERE.
    #
    # FIXED: an UNKNOWN node_id. Sync::Trash.restore opens with find_by!, which raises
    # ActiveRecord::RecordNotFound -- a class from outside the port's own vocabulary, where
    # Share#undelete and S3#undelete both answer FileLayer::NotFound. Harmless today only because
    # TrashController happens to rescue both; a future caller rescuing FileLayer::* would miss it.
    # The existence check below is what keeps the port's error taxonomy closed.
    #
    # NOT FIXED, AND STRUCTURAL RATHER THAN ARBITRARY: undeleting an ALREADY-LIVE node. Chunk
    # treats it as an idempotent success (Sync::Trash.restore early-returns [node, nil]); share and
    # s3 raise NotFound, because their lookup is scoped `deleted: true` and there are no bytes in
    # .trash to move back for a node that is already live. So a double-click on Restore reads
    # "Restored X." on chunk and "Couldn't restore that item." on share/s3. Unifying it would mean
    # either making chunk raise about a file that IS restored, or making share/s3 claim a byte move
    # they did not perform. Recorded, not papered over.
    def undelete(user, node_id: nil)
      # NOT live_node!: this operates on a tombstone by definition, so a `.present` lookup would
      # answer NotFound for exactly the rows this verb exists to act on.
      user.nodes.exists?(node_id:) ||
        raise(NotFound, "node #{node_id.inspect} does not exist")
      node, seq = Sync::Trash.restore(user:, node_id:, to_root: true)
      Sync::LibraryChannel.broadcast_change(user, seq) if seq
      file_info(node, current_version_for(user, node)&.size)
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

    # WAS Node#current_version, which is host code querying an engine table (`versions` moves to the
    # sync engine; `nodes` does not). Moved here because this adapter is the one file allowed to know
    # versions exist, and it was the only caller.
    #
    # NOT a convenience wrapper to reuse widely: it is one query per node, and the codebase already
    # routes bulk paths around it for exactly that reason -- V1::TrashController uses
    # Sync.load_version_sizes with a comment saying why. If a second caller ever wants this, that is
    # the signal it should be batched, not shared.
    def current_version_for(user, node)
      return nil if node.current_version_id.blank?
      user.versions.find_by(version_id: node.current_version_id)
    end

    # ONE QUESTION, ONE ANSWER, ONE MESSAGE -- "is any live node of any kind already at
    # (parent_node_id, name)?" -- shared by mkdir and move, which asked it in two places with two
    # spellings of one identical query and one identical message.
    #
    # DELIBERATELY MIRRORS FileLayer::S3#destination_vacant!, which has answered exactly this
    # across write/mkdir/move/undelete since Phase 3 and whose own comment cites §14a APPROVINGLY,
    # as the reason to share. That distinction is the one to hold on to, because §14a ALSO records
    # a bug caused by sharing: what must not be shared is per-op REMEDIATION ADVICE -- WRITE_MSG
    # above stays its own constant (and would stay separate from any future refusal like it)
    # because "go and use this other door" names a DIFFERENT door per verb. "The destination is
    # occupied" is not advice; it is one fact, identical whichever verb tripped over it.
    #
    # SHARE INLINES THIS FOUR TIMES, IN FOUR WORDINGS, AND THAT IS SHARE'S CORRECT ANSWER, NOT A
    # LAPSE: it holds a row AND a real file on disk, so its move and undelete must special-case
    # `dest == src` in path terms. Chunk keys on a single canonical row per node, like S3 -- which
    # is why S3 is the sibling to copy here and Share is not.
    #
    # No `kind:` parameter, unlike S3's: that one exists for S3's file-key-vs-dir-marker namespace
    # split, and chunk has no such split for it to do anything with.
    #
    # UNDELETE (§14a's fourth port verb) DELIBERATELY DOES NOT CALL THIS. Sync::Trash.restore has
    # no collision check anywhere in it, and adding one would change sync-engine semantics that the
    # device API shares -- so chunk's revive can land two live nodes on one (parent, name) where
    # share and s3 refuse. That divergence is recorded in #undelete's own comment rather than
    # closed here. If it is ever closed, note that Share words it "occupied -- undelete must not
    # clobber", which reads better for a file coming BACK than "already exists": inline that wording
    # rather than bending this message. A better error beats DRY.
    def destination_vacant!(user, parent_node_id, name, except_node_id: nil)
      scope = user.nodes.present.where(parent_node_id:, name:)
      scope = scope.where.not(node_id: except_node_id) if except_node_id
      occupant = scope.first
      raise UnsupportedOperation, "#{name.inspect} already exists as a #{occupant.kind}" if occupant
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
