"""GET /hello?name=... behind an HTTP API (payload format 2.0)."""
import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def handler(event, context):
    logger.debug("Event: %s", json.dumps(event))
    name = (event.get("queryStringParameters") or {}).get("name", "world")
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": f"Hello, {name}!", "requestId": context.aws_request_id}),
    }
