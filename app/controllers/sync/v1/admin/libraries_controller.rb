module Sync
  module V1
    module Admin
      # PROVISIONS A NEW LIBRARY OVER HTTP: a User plus its first Device, in one call -- Arc C's
      # answer to "how does a maker user's first sync get its own library without an operator
      # running `sync:device:issue` by hand for every signup." (design:
      # 2026-08-23-stage-5-engine-leaves-the-process-design.md, "Arc C -- per-user enrolment", in
      # the sibling chaim354/tinkerex repo.)
      #
      # THIS BREAKS THAT SAME DESIGN'S OWN §6 CLAIM, "ZERO NEW SERVER ENDPOINTS ARE REQUIRED" --
      # STATED HERE RATHER THAN LEFT FOR THE COMMIT MESSAGE ALONE TO CARRY, because a reader who
      # opens this file having read that claim elsewhere deserves the correction where the new
      # endpoint actually is. That claim was about the FILE-LAYER VERBS -- stat, read, write,
      # mkdir, move, delete, undelete, the two-phase upload -- every one of which already had a v1
      # endpoint before chunk_remote existed to reach it over HTTP instead of in-process.
      # PROVISIONING was never among them: nothing in this engine, and nothing chunk_remote ever
      # called, has ever minted a new sync USER before. This is a genuinely new capability, not a
      # new transport for an old one.
      #
      # NOT UNDER Sync::V1::BaseController, ON PURPOSE, THE SAME WAY Sync::V1::Chunks::BlobController
      # ISN'T. That base class `include`s Sync::V1::Authentication -- bearer DEVICE-token auth,
      # checked against every Device any user has ever registered (Device.authenticate). Inheriting
      # it and then skipping its authentication before_action would be a checked-out door, not a
      # door that was never built: still readable as "device tokens are accepted here" to anyone who
      # only reads the ancestry, one `skip_before_action` away from actually being true again by
      # accident. Inheriting ActionController::API directly instead means there is no ancestor
      # anywhere in this class's chain that calls Device.authenticate -- a device token presented to
      # POST /v1/admin/libraries is not "checked and rejected" by this code, it is simply not a
      # credential any path here reads, structurally, the same way a maker web session cookie is not
      # a credential the v1 API has any path that reads. That distinction matters here specifically
      # because this endpoint MINTS a device's own credentials: letting a device token stand in for
      # the operator credential that authorizes minting more of them would be a privilege-escalation
      # ladder from "any one device, anywhere" to "every library this server holds."
      #
      # THE FIVE JSON RESCUES BELOW ARE DUPLICATED FROM Sync::V1::BaseController, NOT SHARED WITH
      # IT. Sharing them would mean either this controller inherits BaseController (the checked-out
      # door above) or BaseController's authentication concern gets pulled into a still-smaller
      # common ancestor for two callers where, until this file, there was only ever one -- a new
      # abstraction not worth building for ten duplicated lines. Duplicating keeps "this class never
      # authenticates a device" verifiable by reading its own ancestor chain, not by tracing which
      # before_actions got skipped where.
      class LibrariesController < ActionController::API
        rescue_from ActiveRecord::RecordNotFound, with: :not_found
        rescue_from ActionController::ParameterMissing, with: :bad_request
        rescue_from ActiveRecord::RecordInvalid, with: :unprocessable
        rescue_from ArgumentError, with: :unprocessable
        rescue_from ActiveRecord::RecordNotUnique, with: :conflict

        before_action :authenticate_admin!

        # POST /v1/admin/libraries  { email, name? }  ->  { user_id, device_id, device_token }
        def create
          email = params.require(:email)

          # IDEMPOTENCY, DECIDED: A REPEAT CALL FOR THE SAME EMAIL REFUSES (409); IT NEVER MINTS A
          # SECOND DEVICE ONTO THE EXISTING LIBRARY AND IT CERTAINLY NEVER CREATES A SECOND USER
          # ROW (the DB-level unique index on users.email would refuse that part regardless -- see
          # host/db/schema.rb and test/dummy/db/schema.rb).
          #
          # The tempting alternative is `User.find_or_create_by!`, exactly what `sync:device:issue`
          # already does (host/lib/tasks/devices.rake) -- reasonable THERE because an OPERATOR
          # typing that command a second time for an email they recognize clearly wants "another
          # device on that library," and there is no question of WHO is asking: whoever is at that
          # shell. This endpoint has no equivalent guarantee. It is reachable by anything holding
          # SYNC_ADMIN_TOKEN -- a provisioning script, specifically the design's own maker-repo
          # caller, described as calling this "lazily, on a user's first library use" and required
          # to create "exactly once per user, UNDER CONCURRENCY." A find_or_create_by-shaped answer
          # here would turn every retried or duplicated provisioning call into a FRESH, FULL-ACCESS
          # device_token for a library that already exists -- silently, with nothing telling the
          # caller anything unusual happened, and no bound on how many valid credentials accumulate
          # for one library from an ordinary retry loop. That is "a second library silently" one
          # layer down: the USER row cannot literally duplicate, but the CREDENTIAL would, and the
          # credential is the half that actually matters for a door whose entire job is minting one.
          #
          # Refusing instead puts retry-safety where the design already puts it -- on the CALLER
          # (maker repo Task 5: "use a lock or a unique constraint and prove it with a concurrent
          # test"): a caller that wants idempotent provisioning stores the token it got back and
          # simply never calls this a second time for the same user, rather than leaning on this
          # endpoint to paper over not having done so.
          if User.exists?(email:)
            return render json: { error: "email_taken" }, status: :conflict
          end

          # A genuine RACE loses here instead, and still never duplicates: two requests that both
          # slip past the check above cannot both persist, because users.email carries a DB-level
          # unique index. Whichever loses raises either User.create!'s own uniqueness validation
          # (ActiveRecord::RecordInvalid, rescued above to 422) or, if the two inserts interleave
          # past that validation, the index itself (ActiveRecord::RecordNotUnique, rescued above to
          # 409 -- the same status the check above already answers). Both outcomes are a refusal,
          # never a silent duplicate; which exact one fires depends on timing this endpoint does not
          # control, and forcing them to agree is not worth the complexity for an operator-gated
          # door this rarely concurrent in practice.
          user = User.create!(email:)
          device = Device.register!(user:, name: params[:name].presence || "device")

          render json: { user_id: user.id, device_id: device.id, device_token: device.plaintext_token },
                 status: :created
        end

        private

        # An unset/blank SYNC_ADMIN_TOKEN must never mean "allow" -- decided here as REFUSE THE
        # ENDPOINT, NOT REFUSE THE BOOT, and argued here because a boot guard has no natural home
        # near a single-action controller and burying the argument in an initializer no reader would
        # think to open is worse than stating it where the check actually runs.
        #
        # lib/sync/postgres_pooler_check.rb (this repo) and the maker repo's LibraryBackendCheck
        # both refuse to BOOT on a bad config -- but both guard a setting EVERY SINGLE REQUEST
        # depends on for correctness: a statement-mode pooler deadlocks or corrupts the changelog
        # seq allocator on every commit; a misconfigured library backend 500s the ENTIRE v1 API.
        # SYNC_ADMIN_TOKEN gates exactly one narrow, additive, optional endpoint that most
        # deployments -- self-host, or any deployment still minting its one library by hand with
        # `sync:device:issue` -- never call at all. Refusing to boot the WHOLE server, breaking file
        # sync for every already-provisioned device, because a feature nobody may be using yet is
        # unconfigured would be a blast radius wildly disproportionate to the omission. Refusing
        # just the request, with a clear, named 503, is self-diagnosing (an operator who tries the
        # endpoint learns exactly what is missing, immediately) and costs every other endpoint
        # nothing. Nothing here stops a future caller from ALSO adding a boot-time WARNING (never a
        # refusal) if operators want earlier visibility; that is a smaller, separate decision this
        # one does not need to make.
        #
        # Refusing HERE, before any comparison, is what makes "unset never means allow" true
        # STRUCTURALLY rather than true as a side effect of secure_compare's own behaviour: with
        # this guard, `expected` never reaches the comparison at all when it is blank, so there is
        # no code path -- not even an unlikely one -- where a blank credential on either side can
        # satisfy the check. (ActiveSupport::SecurityUtils.secure_compare would in fact refuse a
        # blank `expected` safely too: two strings of different bytesize never reach the
        # constant-time comparison inside it. But this guard does not lean on that, so the safety
        # does not depend on a future reader remembering it.)
        def authenticate_admin!
          expected = ENV["SYNC_ADMIN_TOKEN"]
          if expected.blank?
            return render json: { error: "admin_provisioning_disabled" }, status: :service_unavailable
          end

          provided = request.authorization.to_s.delete_prefix("Bearer ").strip
          return if ActiveSupport::SecurityUtils.secure_compare(provided, expected)

          render json: { error: "unauthorized" }, status: :unauthorized
        end

        def not_found(_e) = render(json: { error: "not_found" }, status: :not_found)
        def bad_request(e) = render(json: { error: e.message }, status: :bad_request)
        def unprocessable(e) = render(json: { error: e.message }, status: :unprocessable_entity)
        def conflict(e) = render(json: { error: e.message }, status: :conflict)
      end
    end
  end
end
