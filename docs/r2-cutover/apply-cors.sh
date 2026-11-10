#!/usr/bin/env bash
#
# apply-cors.sh — apply ./cors.json to the R2 bucket.
#
# The CORS policy is ONLY needed for the WEB UI (browser-side PUT/GET straight to R2).
# The desktop/daemon client is not a browser and is not subject to CORS, so this step
# can be deferred until the web UI ships (docs/r2-migration.md §2).
#
# IMPORTANT: edit cors.json first and replace the placeholder origin
# "https://app.yourdomain.com" with your REAL production web origin. Do NOT use a
# wildcard "*" in production — a leaked presigned URL could then be replayed from any
# site's browser context.
#
# Two ways to apply, auto-detected:
#   1) wrangler (preferred):  wrangler r2 bucket cors put <bucket> --rules ./cors.json
#   2) aws s3api PutBucketCors against the R2 S3 endpoint (fallback if no wrangler).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORS_FILE="${CORS_FILE:-$HERE/cors.json}"
R2_BUCKET="${R2_BUCKET:?set R2_BUCKET, e.g. maker-chunks-prod}"

[ -f "$CORS_FILE" ] || { echo "CORS file not found: $CORS_FILE" >&2; exit 1; }

# Refuse to apply a still-placeholder origin (foot-gun guard).
if grep -q "app.yourdomain.com" "$CORS_FILE"; then
  echo "ERROR: $CORS_FILE still has the placeholder origin 'app.yourdomain.com'." >&2
  echo "Edit it to your real web origin before applying." >&2
  exit 1
fi
# Refuse a wildcard origin in the committed policy.
if grep -Eq '"\*"' "$CORS_FILE" && grep -A2 AllowedOrigins "$CORS_FILE" | grep -q '"\*"'; then
  echo "ERROR: wildcard '*' origin detected in AllowedOrigins — not allowed in prod." >&2
  exit 1
fi

echo "About to apply CORS policy to R2 bucket '$R2_BUCKET' from: $CORS_FILE"
echo "----- policy -----"
cat "$CORS_FILE"
echo "------------------"

if command -v wrangler >/dev/null 2>&1; then
  echo "Applying via wrangler..."
  wrangler r2 bucket cors put "$R2_BUCKET" --rules "$CORS_FILE"
  echo "Done. Verify with: wrangler r2 bucket cors list $R2_BUCKET"
elif command -v aws >/dev/null 2>&1; then
  : "${R2_ENDPOINT:?set R2_ENDPOINT for the aws fallback}"
  : "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID}"
  : "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY}"
  echo "wrangler not found; applying via aws s3api PutBucketCors..."
  # aws s3api wants {"CORSRules":[...]}; our cors.json is the bare rules array, so wrap it.
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  printf '{"CORSRules":' > "$tmp"
  cat "$CORS_FILE" >> "$tmp"
  printf '}' >> "$tmp"
  AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
  AWS_REGION="${R2_REGION:-auto}" \
    aws s3api put-bucket-cors \
      --endpoint-url "$R2_ENDPOINT" \
      --bucket "$R2_BUCKET" \
      --cors-configuration "file://$tmp"
  echo "Done. Verify with: aws s3api get-bucket-cors --endpoint-url $R2_ENDPOINT --bucket $R2_BUCKET"
else
  echo "ERROR: neither 'wrangler' nor 'aws' found on PATH. Install one, or apply the" >&2
  echo "policy in cors.json via the Cloudflare dashboard (R2 -> bucket -> Settings -> CORS)." >&2
  exit 1
fi
