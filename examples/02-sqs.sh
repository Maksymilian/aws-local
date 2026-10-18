#!/usr/bin/env bash
# SQS: send/receive/delete, and a poison message landing in the dead-letter queue.
source "$(dirname "$0")/_env.sh"

QUEUE=$(queue_url orders-queue)
drain orders-queue > /dev/null
drain orders-dlq > /dev/null

step "Send a message with attributes"
aws sqs send-message --queue-url "$QUEUE" \
  --message-body '{"orderId": "o-1001", "action": "reserve-stock"}' \
  --message-attributes 'priority={DataType=String,StringValue=high}' \
  --query MessageId --output text

step "Receive it, process it, delete it (the normal consumer loop)"
MSG=$(aws sqs receive-message --queue-url "$QUEUE" --message-attribute-names All --output json)
jq '.Messages[0] | {Body, priority: .MessageAttributes.priority.StringValue}' <<< "$MSG"
aws sqs delete-message --queue-url "$QUEUE" --receipt-handle "$(jq -r '.Messages[0].ReceiptHandle' <<< "$MSG")"

step "Send a poison message and fail to process it twice (maxReceiveCount = 2)"
aws sqs send-message --queue-url "$QUEUE" --message-body '{"orderId": "o-broken"}' > /dev/null
for attempt in 1 2; do
  # visibility-timeout 0 = the consumer "crashed" and the message is immediately visible again
  aws sqs receive-message --queue-url "$QUEUE" --visibility-timeout 0 \
    --query 'Messages[0].Body' --output text > /dev/null
  echo "attempt $attempt: received, not deleted"
done
# The next receive notices the receive count was exceeded and moves the message to the DLQ.
aws sqs receive-message --queue-url "$QUEUE" > /dev/null

step "The message is now in orders-dlq"
drain orders-dlq 2
