#!/usr/bin/env bash
# Runs inside the LocalStack container once every service is ready
# (see https://docs.localstack.cloud/aws/capabilities/config/initialization-hooks/).
# Provisions the resources of a tiny "orders" app that the examples use:
#
#   S3 demo-bucket/incoming/*.json ──▶ Lambda order-processor ──▶ DynamoDB orders
#                                                │
#                                                ▼
#                                     SNS order-events ──▶ SQS billing-queue  (all events)
#                                                     └──▶ SQS shipping-queue (OrderPlaced only)
#
#   SQS orders-queue (redrives to orders-dlq after 2 failed receives)
#   EventBridge demo-bus, rule high-value-orders ──▶ SQS order-audit-queue
#   Secrets Manager demo/db-credentials, SSM /demo/config/*
set -euo pipefail

ACCOUNT_ID=000000000000
REGION="${AWS_DEFAULT_REGION:-eu-central-1}"

queue_arn() { echo "arn:aws:sqs:${REGION}:${ACCOUNT_ID}:$1"; }
# Create a resource without dumping the API response into the container log.
create() { awslocal "$@" > /dev/null; }

echo "==> S3"
create s3 mb s3://demo-bucket

echo "==> SQS (work queue + dead-letter queue)"
create sqs create-queue --queue-name orders-dlq
create sqs create-queue --queue-name orders-queue --attributes "$(printf \
  '{"RedrivePolicy": "{\\"deadLetterTargetArn\\":\\"%s\\",\\"maxReceiveCount\\":\\"2\\"}"}' \
  "$(queue_arn orders-dlq)")"

echo "==> SNS fan-out to SQS"
TOPIC_ARN=$(awslocal sns create-topic --name order-events --query TopicArn --output text)
create sqs create-queue --queue-name billing-queue
create sqs create-queue --queue-name shipping-queue
create sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
  --notification-endpoint "$(queue_arn billing-queue)" \
  --attributes RawMessageDelivery=true
create sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
  --notification-endpoint "$(queue_arn shipping-queue)" \
  --attributes '{"RawMessageDelivery": "true", "FilterPolicy": "{\"eventType\": [\"OrderPlaced\"]}"}'

echo "==> DynamoDB"
create dynamodb create-table --table-name orders \
  --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=orderId,AttributeType=S AttributeName=customerId,AttributeType=S \
  --key-schema AttributeName=orderId,KeyType=HASH \
  --global-secondary-indexes '[{
      "IndexName": "customerId-index",
      "KeySchema": [{"AttributeName": "customerId", "KeyType": "HASH"}],
      "Projection": {"ProjectionType": "ALL"}
    }]'

echo "==> Secrets Manager + SSM Parameter Store"
create secretsmanager create-secret --name demo/db-credentials \
  --secret-string '{"username": "app", "password": "local-dev-only"}'
create ssm put-parameter --name /demo/config/page-size --type String --value "25"
create ssm put-parameter --name /demo/config/new-checkout-enabled --type String --value "true"
create ssm put-parameter --name /demo/config/api-key --type SecureString --value "local-api-key"

echo "==> EventBridge rule routing high-value orders to SQS"
create events create-event-bus --name demo-bus
create sqs create-queue --queue-name order-audit-queue
create events put-rule --name high-value-orders --event-bus-name demo-bus \
  --event-pattern '{
      "source": ["demo.orders"],
      "detail-type": ["OrderPlaced"],
      "detail": {"total": [{"numeric": [">=", 100]}]}
    }'
create events put-targets --rule high-value-orders --event-bus-name demo-bus \
  --targets "Id=audit-queue,Arn=$(queue_arn order-audit-queue)"

echo "==> Lambda triggered by S3 uploads"
# IAM isn't enforced by default in LocalStack, but the role has to exist like it would in AWS.
ROLE_ARN=$(awslocal iam create-role --role-name order-processor-role \
  --assume-role-policy-document '{"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]}' \
  --query Role.Arn --output text)

python3 -m zipfile -c /tmp/order-processor.zip /opt/lambda/order_processor/handler.py
create lambda create-function --function-name order-processor \
  --runtime python3.13 --handler handler.handler --timeout 30 \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/order-processor.zip \
  --environment "Variables={ORDERS_TABLE=orders,ORDER_EVENTS_TOPIC_ARN=${TOPIC_ARN}}"
awslocal lambda wait function-active-v2 --function-name order-processor

LAMBDA_ARN=$(awslocal lambda get-function --function-name order-processor \
  --query Configuration.FunctionArn --output text)
create s3api put-bucket-notification-configuration --bucket demo-bucket \
  --notification-configuration "$(printf '{"LambdaFunctionConfigurations": [{
      "LambdaFunctionArn": "%s",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {"Key": {"FilterRules": [
        {"Name": "prefix", "Value": "incoming/"},
        {"Name": "suffix", "Value": ".json"}
      ]}}
    }]}' "$LAMBDA_ARN")"

echo "==> Done. Resources are ready."
