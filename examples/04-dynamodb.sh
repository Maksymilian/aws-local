#!/usr/bin/env bash
# DynamoDB: put/get, query a GSI, conditional and atomic updates.
source "$(dirname "$0")/_env.sh"

TABLE=orders

step "Put a few orders"
put_order() {
  aws dynamodb put-item --table-name "$TABLE" --item "{
    \"orderId\":    {\"S\": \"$1\"},
    \"customerId\": {\"S\": \"$2\"},
    \"total\":      {\"N\": \"$3\"},
    \"status\":     {\"S\": \"PLACED\"}
  }"
  echo "put $1 ($2, $3)"
}
put_order o-3001 c-alice 49.99
put_order o-3002 c-alice 120.00
put_order o-3003 c-bob 15.50

step "Get one order by its key"
aws dynamodb get-item --table-name "$TABLE" --key '{"orderId": {"S": "o-3001"}}' \
  --query Item --output json

step "Query all of alice's orders through the customerId-index GSI"
aws dynamodb query --table-name "$TABLE" --index-name customerId-index \
  --key-condition-expression "customerId = :c" \
  --expression-attribute-values '{":c": {"S": "c-alice"}}' \
  --query 'Items[].{orderId: orderId.S, total: total.N, status: status.S}' --output table

step "Ship o-3001, but only if it is still PLACED (optimistic concurrency)"
aws dynamodb update-item --table-name "$TABLE" --key '{"orderId": {"S": "o-3001"}}' \
  --update-expression "SET #s = :shipped ADD version :one" \
  --condition-expression "#s = :placed" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":shipped": {"S": "SHIPPED"}, ":placed": {"S": "PLACED"}, ":one": {"N": "1"}}' \
  --return-values UPDATED_NEW --query Attributes --output json

step "Shipping it a second time fails the condition"
if ! aws dynamodb update-item --table-name "$TABLE" --key '{"orderId": {"S": "o-3001"}}' \
  --update-expression "SET #s = :shipped" \
  --condition-expression "#s = :placed" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":shipped": {"S": "SHIPPED"}, ":placed": {"S": "PLACED"}}' 2>&1; then
  echo "(expected: ConditionalCheckFailedException)"
fi
