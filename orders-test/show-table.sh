#!/usr/bin/env bash
# Prints every item in the orders table (local DynamoDB) as plain JSON.
set -euo pipefail
TABLE=${TABLE:-orders-local}
EP=${ENDPOINT:-http://localhost:8000}
export AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local AWS_DEFAULT_REGION=eu-central-1
unset AWS_PROFILE

echo "\$ scan $TABLE"
aws dynamodb scan --table-name "$TABLE" --endpoint-url "$EP" --output json | jq -r '
  # DynamoDB attribute values -> plain JSON (handles nested maps and lists)
  def plain: if type != "object" then .
    elif has("S") then .S elif has("N") then (.N | tonumber) elif has("BOOL") then .BOOL
    elif has("NULL") then null elif has("M") then (.M | map_values(plain))
    elif has("L") then (.L | map(plain)) else . end;
  (.Items[] | map_values(plain) | "  " + tojson),
  "  (items: \(.Count))"'
