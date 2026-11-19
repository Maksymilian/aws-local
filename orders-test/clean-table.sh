#!/usr/bin/env bash
# Deletes all items from the orders table (local DynamoDB).
set -euo pipefail
TABLE=${TABLE:-orders-local}
EP=${ENDPOINT:-http://localhost:8000}
export AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local AWS_DEFAULT_REGION=eu-central-1
unset AWS_PROFILE

n=0
while read -r key; do
  aws dynamodb delete-item --table-name "$TABLE" --key "$key" --endpoint-url "$EP"
  n=$((n + 1))
done < <(aws dynamodb scan --table-name "$TABLE" --endpoint-url "$EP" \
           --projection-expression orderId --output json | jq -c '.Items[]')
echo "Cleared $TABLE ($n items)"
