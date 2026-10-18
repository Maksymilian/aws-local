# Sourced by every example. Points the regular AWS CLI at LocalStack —
# the same env vars work for the AWS SDKs (Java, Node, Python, Go, ...).
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ACCESS_KEY_ID=test        # any value works; "test" maps to account 000000000000
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-central-1}"
export AWS_DEFAULT_OUTPUT=json
export AWS_PAGER=""
# Ignore ~/.aws entirely so a real profile (SSO, output format, ...) can't leak in.
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
unset AWS_PROFILE AWS_SESSION_TOKEN

set -euo pipefail

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

queue_url() { aws sqs get-queue-url --queue-name "$1" --query QueueUrl --output text; }

# Receive and delete everything currently in a queue, printing message bodies.
drain() {
  local url
  url=$(queue_url "$1")
  while true; do
    local msgs
    msgs=$(aws sqs receive-message --queue-url "$url" --max-number-of-messages 10 \
      --wait-time-seconds "${2:-0}" --output json)
    [[ -z "$msgs" || $(jq '.Messages | length' <<< "$msgs") == 0 ]] && break
    jq -r '.Messages[].Body' <<< "$msgs"
    jq -r '.Messages[].ReceiptHandle' <<< "$msgs" | while read -r handle; do
      aws sqs delete-message --queue-url "$url" --receipt-handle "$handle"
    done
  done
}
