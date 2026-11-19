#!/usr/bin/env bash
# Writes the EventBridge test events to events/, starting from SAM's template.
# (This SAM version has no "eventbridge" service; "cloudwatch scheduled-event" is the same shape.)
set -euo pipefail
cd "$(dirname "$0")"
export SAM_CLI_TELEMETRY=0

# detail = business payload only. Invocation metadata (source, request id, ...)
# is read by the Lambda from the real EventBridge envelope, never from detail.
# The same detail is sent as the REST API body by the API test flow.
base=$(sam local generate-event cloudwatch scheduled-event 2>/dev/null | sed -n '/^{/,/^}/p')

gen() { # gen <file> <detail-type> <detail-json>
  echo "$base" | jq --arg dt "$2" --argjson d "$3" --arg id "$(cat /proc/sys/kernel/random/uuid)" --arg t "$(date -u +%FT%TZ)" '
    .id = $id | .time = $t | .source = "orders.local" | .["detail-type"] = $dt | .region = "eu-central-1"
    | .resources = [] | .detail = $d' > "events/$1"
  echo "events/$1"
}

mkdir -p events && rm -f events/*.json

# Flow, in order: create -> cancel -> create again -> same create twice (duplicate) -> conflict
gen 01-create-order.json           CreateOrder '{"idempotencyKey":1,"orderId":"order-001","customerId":"cust-001","amount":149.99}'
gen 02-cancel-order.json           CancelOrder '{"idempotencyKey":2,"orderId":"order-001","customerId":"cust-001","reason":"changed my mind"}'
gen 03-create-order-again.json     CreateOrder '{"idempotencyKey":3,"orderId":"order-001","customerId":"cust-001","amount":149.99}'
gen 04-create-order-duplicate.json CreateOrder '{"idempotencyKey":3,"orderId":"order-001","customerId":"cust-001","amount":149.99}'
gen 05-create-order-conflict.json  CreateOrder '{"idempotencyKey":4,"orderId":"order-001","customerId":"cust-001","amount":999.00}'
# Validation failures
gen 06-missing-order-id.json       CreateOrder '{"idempotencyKey":5,"customerId":"cust-002","amount":59.50}'
gen 07-missing-customer-id.json    CreateOrder '{"idempotencyKey":6,"orderId":"order-003","amount":20.00}'
