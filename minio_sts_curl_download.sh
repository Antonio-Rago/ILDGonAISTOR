#!/usr/bin/env bash
# Download an object from MinIO using OIDC -> STS (AssumeRoleWithWebIdentity)
# and a SigV4-signed GET request, all without awscli.
#
# Usage:
#   ID_TOKEN=... ./minio_sts_curl_download.sh <bucket> <object-key> [output-file]
#
# Requirements: bash, curl, openssl, sed, xxd
# Notes:
#   - Ensure ROLE_ARN and MINIO_ENDPOINT are correct for your MinIO.
#   - REGION must be an AWS-valid region name (e.g., eu-north-1).
#   - OBJECT key should be the exact S3 key (avoid weird characters).

set -euo pipefail

# --------- CONFIG (override via env) ---------
ROLE_ARN="arn:minio:iam:eu-north-0::role/jXly73HuL0_nJBDQg9g5hAQ8m4A"
ROLE_ARN="arn:minio:iam:::role/jXly73HuL0_nJBDQg9g5hAQ8m4A"
ROLE_ARN="arn:minio:iam:::role/6fjOfWNrqjJUCfLsZaCiAD3J8k0"

MINIO_ENDPOINT="${MINIO_ENDPOINT:-https://app-minio-openlat.cloud.sdu.dk}"
REGION="${REGION:-eu-north-0}"   # must look like an AWS region (e.g., eu-north-1)
DURATION="${DURATION:-3600}"
# --------------------------------------------

if [[ $# -lt 2 ]]; then
  echo "Usage: ID_TOKEN=... $0 <bucket> <object-key> [output-file]" >&2
  exit 1
fi
: "${ID_TOKEN:?Please export ID_TOKEN (your OIDC web token) before running.}"

BUCKET="$1"
OBJECT="$2"
OUT="${3:-${OBJECT##*/}}"

# Strip scheme, trailing slash for host header
HOST="${MINIO_ENDPOINT#http://}"
HOST="${HOST#https://}"
HOST="${HOST%/}"

# --- Step 1: STS exchange (POST) ---
echo "→ Requesting STS credentials from MinIO..."

STS_XML="$(curl -sS -X POST "${MINIO_ENDPOINT%/}/" \
  --data-urlencode 'Action=AssumeRoleWithWebIdentity' \
  --data-urlencode 'Version=2011-06-15' \
  --data-urlencode "WebIdentityToken=${ID_TOKEN}" \
  --data-urlencode "DurationSeconds=${DURATION}" \
  --data-urlencode "RoleArn=${ROLE_ARN}")"

# Extract fields using sed (tolerates quirky XML headers)
extract() { printf '%s' "$STS_XML" | sed -n "s:.*<$1>\\([^<]*\\)</$1>.*:\\1:p"; }
AK="$(extract AccessKeyId)"
SK="$(extract SecretAccessKey)"
ST="$(extract SessionToken)"
EXP="$(extract Expiration)"

if [[ -z "$AK" || -z "$SK" || -z "$ST" ]]; then
  echo "Failed to obtain creds. Raw response:" >&2
  printf '%s\n' "$STS_XML" >&2
  exit 1
fi
echo "✓ Got temporary creds (expires: $EXP)"

# --- Step 2: Build SigV4-signed GET for /bucket/object ---
# Minimal URL-encoding: replace spaces (avoid exotic chars in keys)
SAFE_OBJECT="${OBJECT// /%20}"
CANONICAL_URI="/${BUCKET}/${SAFE_OBJECT}"

# Timestamps
DATE="$(date -u +"%Y%m%dT%H%M%SZ")"
DATE_SHORT="${DATE:0:8}"

SERVICE="s3"
REQUEST_TYPE="aws4_request"
ALGO="AWS4-HMAC-SHA256"

# Payload hash for empty GET body
PAYLOAD_HASH="$(printf '' | openssl dgst -sha256 | awk '{print $2}')"

# Canonical headers (lowercase keys, newline-terminated)
CANONICAL_HEADERS=$'host:'"$HOST"$'\n''x-amz-content-sha256:'"$PAYLOAD_HASH"$'\n''x-amz-date:'"$DATE"$'\n''x-amz-security-token:'"$ST"$'\n'
SIGNED_HEADERS="host;x-amz-content-sha256;x-amz-date;x-amz-security-token"

# Canonical request
CANONICAL_REQUEST=$'GET\n'"$CANONICAL_URI"$'\n\n'"$CANONICAL_HEADERS"$'\n'"$SIGNED_HEADERS"$'\n'"$PAYLOAD_HASH"
CANONICAL_REQ_HASH="$(printf '%s' "$CANONICAL_REQUEST" | openssl dgst -sha256 | awk '{print $2}')"

CREDENTIAL_SCOPE="${DATE_SHORT}/${REGION}/${SERVICE}/${REQUEST_TYPE}"
STRING_TO_SIGN=$ALGO$'\n'"$DATE"$'\n'"$CREDENTIAL_SCOPE"$'\n'"$CANONICAL_REQ_HASH"
if [[ "${DEBUG:-0}" = "1" ]]; then
  echo "---- CanonicalRequest ----"
  printf '%s\n' "$CANONICAL_REQUEST"
  echo "---- StringToSign ----"
  printf '%s\n' "$STRING_TO_SIGN"
  echo "-------------------------"
fi


# --- Step 3: Derive signing key using HMAC-SHA256 chain ---
hex_hmac () {  # hex_hmac <hexkey> <data>
  printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$1" | awk '{print $2}'
}
bin_hmac_to_hex () {  # bin_hmac_to_hex <keystring> <data> with ascii key
  printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" -binary | xxd -p -c256
}

kDateHex="$(bin_hmac_to_hex "AWS4${SK}"     "$DATE_SHORT")"
kRegionHex="$(hex_hmac       "$kDateHex"    "$REGION")"
kServiceHex="$(hex_hmac      "$kRegionHex"  "$SERVICE")"
kSigningHex="$(hex_hmac      "$kServiceHex" "$REQUEST_TYPE")"

SIGNATURE="$(printf '%s' "$STRING_TO_SIGN" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$kSigningHex" | awk '{print $2}')"

AUTH_HEADER="Authorization: ${ALGO} Credential=${AK}/${CREDENTIAL_SCOPE}, SignedHeaders=${SIGNED_HEADERS}, Signature=${SIGNATURE}"

# --- Step 4: Perform the download ---
URL="${MINIO_ENDPOINT%/}${CANONICAL_URI}"
echo "→ Downloading: $URL"

HTTP_CODE="$(curl -sSL --retry 3 --retry-delay 2 \
  -o "$OUT.part" -w '%{http_code}' \
  -H "host: ${HOST}" \
  -H "x-amz-date: ${DATE}" \
  -H "x-amz-content-sha256: ${PAYLOAD_HASH}" \
  -H "x-amz-security-token: ${ST}" \
  -H "${AUTH_HEADER}" \
  "$URL")"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Download failed: HTTP $HTTP_CODE" >&2
  rm -f "$OUT.part"
  exit 1
fi
mv "$OUT.part" "$OUT"
echo "Saved to: $OUT"
