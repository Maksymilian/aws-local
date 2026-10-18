#!/usr/bin/env bash
# SNS: one publish fans out to several SQS queues; a filter policy narrows what shipping gets.
source "$(dirname "$0")/_env.sh"

TOPIC=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':order-events')].TopicArn" --output text)
drain billing-queue > /dev/null
drain shipping-queue > /dev/null

step "Publish two events with different eventType attributes"
for type in OrderPlaced OrderCancelled; do
  aws sns publish --topic-arn "$TOPIC" \
    --message "{\"orderId\": \"o-2001\", \"event\": \"$type\"}" \
    --message-attributes "eventType={DataType=String,StringValue=$type}" \
    --query MessageId --output text
done

step "billing-queue (no filter) received both"
drain billing-queue 2

step "shipping-queue (FilterPolicy eventType = OrderPlaced) received only one"
drain shipping-queue 2
