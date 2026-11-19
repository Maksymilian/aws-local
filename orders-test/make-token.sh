#!/usr/bin/env bash
# Prints a local API token for a customer: ./make-token.sh cust-001 [ttl-seconds]
# Use it as: curl -H "Authorization: Bearer $(./make-token.sh cust-001)" ...
set -euo pipefail
cd "$(dirname "$0")"
CUSTOMER=${1:?usage: make-token.sh <customerId> [ttl-seconds]}
TTL=${2:-3600}
SECRET=$(jq -r '.Parameters.AUTH_SECRET' env.json)

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
payload=$(printf '{"sub":"%s","exp":%d}' "$CUSTOMER" $(( $(date +%s) + TTL )) | b64url)
sig=$(printf '%s' "$payload" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64url)
echo "$payload.$sig"
