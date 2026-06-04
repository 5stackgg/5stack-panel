#!/usr/bin/env bash
set -euo pipefail

# Only needed when the S3 backend is Backblaze B2 (MinIO deployments handle
# CORS themselves). Allows the browser to PUT demo-upload chunks straight to
# the bucket via presigned URLs. Requires jq and a B2 key with writeBuckets.
#
# Required env: S3_ACCESS_KEY (B2 keyID), S3_SECRET (B2 applicationKey), S3_BUCKET
# Origins: set CORS_ORIGINS as a JSON array, or WEB_DOMAIN to derive it.

: "${S3_ACCESS_KEY:?set S3_ACCESS_KEY (B2 keyID)}"
: "${S3_SECRET:?set S3_SECRET (B2 applicationKey)}"
: "${S3_BUCKET:?set S3_BUCKET}"

if [ -z "${CORS_ORIGINS:-}" ]; then
  : "${WEB_DOMAIN:?set WEB_DOMAIN or CORS_ORIGINS}"
  CORS_ORIGINS="[\"https://${WEB_DOMAIN}\",\"http://localhost:3000\"]"
fi

auth=$(curl -fsS https://api.backblazeb2.com/b2api/v3/b2_authorize_account \
  -u "${S3_ACCESS_KEY}:${S3_SECRET}")
api_url=$(echo "$auth" | jq -r '.apiInfo.storageApi.apiUrl')
token=$(echo "$auth" | jq -r '.authorizationToken')
account_id=$(echo "$auth" | jq -r '.accountId')

bucket=$(curl -fsS "${api_url}/b2api/v3/b2_list_buckets" \
  -H "Authorization: ${token}" -H "Content-Type: application/json" \
  -d "{\"accountId\":\"${account_id}\",\"bucketName\":\"${S3_BUCKET}\"}")
bucket_id=$(echo "$bucket" | jq -r '.buckets[0].bucketId')

if [ "$bucket_id" = "null" ] || [ -z "$bucket_id" ]; then
  echo "bucket ${S3_BUCKET} not found for this key" >&2
  exit 1
fi

cors="[{\"corsRuleName\":\"fivestackBrowserUploads\",\"allowedOrigins\":${CORS_ORIGINS},\"allowedOperations\":[\"s3_put\",\"s3_head\",\"s3_get\"],\"allowedHeaders\":[\"*\"],\"maxAgeSeconds\":3600}]"

curl -fsS "${api_url}/b2api/v3/b2_update_bucket" \
  -H "Authorization: ${token}" -H "Content-Type: application/json" \
  -d "{\"accountId\":\"${account_id}\",\"bucketId\":\"${bucket_id}\",\"corsRules\":${cors}}" \
  | jq '.corsRules'

echo "B2 CORS configured on bucket ${S3_BUCKET} for origins ${CORS_ORIGINS}"
