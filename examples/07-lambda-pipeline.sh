#!/usr/bin/env bash
# End-to-end: S3 upload → Lambda → DynamoDB + SNS → SQS.
# The order-processor function and the S3 trigger are created by init/ready.d/01-provision.sh.
source "$(dirname "$0")/_env.sh"

ORDER_ID="o-$(date +%s)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
drain shipping-queue > /dev/null

step "Upload incoming/$ORDER_ID.json to demo-bucket"
cat > "$TMP/order.json" <<EOF
{"orderId": "$ORDER_ID", "customerId": "c-carol", "total": 89.90,
 "items": [{"sku": "BOOK-42", "qty": 2}]}
EOF
aws s3 cp "$TMP/order.json" "s3://demo-bucket/incoming/$ORDER_ID.json" --no-progress

step "Wait for the Lambda to write it to DynamoDB"
# The first invocation starts the function's container, so give it a moment.
for _ in $(seq 1 30); do
  ITEM=$(aws dynamodb get-item --table-name orders --key "{\"orderId\": {\"S\": \"$ORDER_ID\"}}" \
    --query Item --output json)
  [[ "$ITEM" != "null" ]] && break
  sleep 1
done
jq '{orderId: .orderId.S, status: .status.S, total: .total.N, sourceKey: .sourceKey.S}' <<< "$ITEM"

step "The OrderPlaced event the Lambda published reached shipping-queue"
drain shipping-queue 3

step "Lambda logs (CloudWatch Logs)"
aws logs tail /aws/lambda/order-processor --since 5m | grep -E "START|Stored|END" | tail -3

step "Invoke the function directly with a hand-written S3 event (handy for debugging)"
aws lambda invoke --function-name order-processor \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"Records\": [{\"s3\": {\"bucket\": {\"name\": \"demo-bucket\"},
             \"object\": {\"key\": \"incoming/$ORDER_ID.json\"}}}]}" \
  "$TMP/response.json" --query StatusCode --output text
cat "$TMP/response.json"; echo
drain shipping-queue 2 > /dev/null
