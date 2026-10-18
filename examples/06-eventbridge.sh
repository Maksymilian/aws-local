#!/usr/bin/env bash
# EventBridge: content-based routing. Only orders with total >= 100 reach the audit queue.
source "$(dirname "$0")/_env.sh"

drain order-audit-queue > /dev/null

step "Put two OrderPlaced events on demo-bus (totals 35 and 250)"
for total in 35 250; do
  aws events put-events --entries "[{
    \"EventBusName\": \"demo-bus\",
    \"Source\": \"demo.orders\",
    \"DetailType\": \"OrderPlaced\",
    \"Detail\": \"{\\\"orderId\\\": \\\"o-total-$total\\\", \\\"total\\\": $total}\"
  }]" --query 'Entries[0].EventId' --output text
done

step "order-audit-queue only got the high-value order"
drain order-audit-queue 3 | jq -c '{source, "detail-type": ."detail-type", detail}'
