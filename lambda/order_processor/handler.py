"""Triggered by s3:ObjectCreated on demo-bucket/incoming/*.json.

Reads the uploaded order, stores it in DynamoDB and announces it on SNS.
LocalStack injects AWS_ENDPOINT_URL into the function's environment, so
boto3 talks to LocalStack without any code changes — the same handler
would work unchanged in real AWS.
"""
import json
import os
import urllib.parse
from decimal import Decimal

import boto3

s3 = boto3.client("s3")
sns = boto3.client("sns")
orders = boto3.resource("dynamodb").Table(os.environ["ORDERS_TABLE"])
TOPIC_ARN = os.environ["ORDER_EVENTS_TOPIC_ARN"]


def handler(event, context):
    processed = []
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        order = json.loads(body, parse_float=Decimal)  # DynamoDB rejects floats
        order.update(status="PLACED", sourceKey=key)
        orders.put_item(Item=order)

        sns.publish(
            TopicArn=TOPIC_ARN,
            Message=json.dumps({"orderId": order["orderId"], "total": str(order["total"])}),
            MessageAttributes={"eventType": {"DataType": "String", "StringValue": "OrderPlaced"}},
        )
        print(f"Stored and published order {order['orderId']} from s3://{bucket}/{key}")
        processed.append(order["orderId"])

    return {"processed": processed}
