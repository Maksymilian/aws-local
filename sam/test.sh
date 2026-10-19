#!/usr/bin/env bash
# Tests the functions in template.yaml with nothing but the SAM CLI and Docker: no LocalStack,
# no AWS account. Every invocation runs in the same Lambda runtime image AWS uses.
#
#   1. sam validate --lint
#   2. sam local invoke with the events in events/ and with events from sam local generate-event
#   3. sam local start-api, then real HTTP requests with curl
#
# SAM_API_PORT changes the port used in step 3 (default 3300).
set -euo pipefail
cd "$(dirname "$0")"

# Dummy credentials and no ~/.aws, so a real profile (SSO, ...) is never touched.
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
unset AWS_PROFILE AWS_SESSION_TOKEN
export SAM_CLI_TELEMETRY=0

API_PORT="${SAM_API_PORT:-3300}"
API_PID=""
LOG=$(mktemp)   # output of the last sam command: container logs, START/END/REPORT lines
FAILED=0
trap '[[ -n "$API_PID" ]] && kill "$API_PID" 2>/dev/null; rm -f "$LOG"' EXIT

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# check DESCRIPTION JSON JQ_FILTER: passes when the filter is true for JSON.
check() {
  if jq -e "$3" <<< "$2" > /dev/null 2>&1; then
    printf '  \033[32mPASS\033[0m %s\n' "$1"
  else
    printf '  \033[31mFAIL\033[0m %s\n       got: %s\n' "$1" "$2"
    tail -n 15 "$LOG" | sed 's/^/       | /'
    FAILED=$((FAILED + 1))
  fi
}

# invoke FUNCTION EVENT_FILE [sam args...]: prints the function's return value.
# EVENT_FILE "-" reads the event from stdin.
invoke() {
  local fn=$1 event=$2; shift 2
  sam local invoke "$fn" --event "$event" "$@" 2> "$LOG"
}

# request METHOD PATH [BODY]: prints {statusCode, body} in the shape the Lambda itself returns,
# so the same checks work for invoke and for the HTTP API.
request() {
  local out
  out=$(curl -s -X "$1" -H 'Content-Type: application/json' ${3:+--data "$3"} \
    -w '\n%{http_code}' "http://127.0.0.1:$API_PORT$2")
  jq -n --arg body "${out%$'\n'*}" --arg code "${out##*$'\n'}" '{statusCode: ($code | tonumber), $body}'
}

step "Validate template.yaml"
sam validate --lint

step "sam local invoke with the events in events/"
check "HelloFunction greets the name from the query string" \
  "$(invoke HelloFunction events/hello.json)" \
  '.statusCode == 200 and (.body | fromjson | .message == "Hello, Ada!")'

check "CreateOrderFunction accepts a valid order" \
  "$(invoke CreateOrderFunction events/create-order.json)" \
  '.statusCode == 201 and (.body | fromjson | .status == "ACCEPTED")'

check "CreateOrderFunction rejects an invalid order and lists all 3 problems" \
  "$(invoke CreateOrderFunction events/create-order-invalid.json)" \
  '.statusCode == 400 and (.body | fromjson | .errors | length == 3)'

check "--parameter-overrides MaxOrderTotal=50 makes the same valid order (89.90) too expensive" \
  "$(invoke CreateOrderFunction events/create-order.json --parameter-overrides MaxOrderTotal=50)" \
  '.statusCode == 400 and (.body | fromjson | .errors == ["total 89.90 exceeds the limit of 50"])'

check "QueueWorkerFunction reports only the 2 bad messages of 3 as batch item failures" \
  "$(invoke QueueWorkerFunction events/sqs-orders.json)" \
  '[.batchItemFailures[].itemIdentifier] == ["msg-bad-json", "msg-bad-order"]'

step "sam local invoke with events from sam local generate-event"
ORDER='{"orderId": "o-3001", "customerId": "c-dave", "total": 15, "items": [{"sku": "CUP-3", "qty": 1}]}'

# The HTTP API generator base64-encodes the body, which exercises that branch of the handler.
check "CreateOrderFunction decodes a base64-encoded body" \
  "$(sam local generate-event apigateway http-api-proxy --method POST --path /orders --body "$ORDER" \
    | invoke CreateOrderFunction -)" \
  '.statusCode == 201'

# The SQS generator pastes --body into its JSON template unescaped, so escape the quotes first.
check "QueueWorkerFunction accepts a valid generated message" \
  "$(sam local generate-event sqs receive-message --body "${ORDER//\"/\\\"}" \
    | invoke QueueWorkerFunction -)" \
  '.batchItemFailures == []'

step "sam local start-api on port $API_PORT"
sam local start-api --port "$API_PORT" > "$LOG" 2>&1 &
API_PID=$!
# Any HTTP answer, even a 404 for "/", means the server is listening.
for _ in $(seq 1 30); do
  curl -s -o /dev/null "http://127.0.0.1:$API_PORT/" && break
  kill -0 "$API_PID" 2>/dev/null || { cat "$LOG" >&2; exit 1; }   # died, e.g. port in use
  sleep 1
done

check "GET /hello?name=Ada returns 200 and a greeting" \
  "$(request GET '/hello?name=Ada')" \
  '.statusCode == 200 and (.body | fromjson | .message == "Hello, Ada!")'

check "POST /orders with a valid order returns 201" \
  "$(request POST /orders "$ORDER")" \
  '.statusCode == 201 and (.body | fromjson | .orderId == "o-3001")'

check "POST /orders with a malformed body returns 400" \
  "$(request POST /orders '{"orderId": ')" \
  '.statusCode == 400 and (.body | fromjson | .errors == ["body is not valid JSON"])'

step "Result"
if (( FAILED )); then
  printf '\033[31m%d check(s) failed\033[0m\n' "$FAILED"
  exit 1
fi
printf '\033[32mAll checks passed\033[0m\n'
