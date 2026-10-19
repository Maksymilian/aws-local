"""POST /orders behind an HTTP API: answers 201 for a valid order, 400 otherwise."""
import base64
import json
import logging
import os
from decimal import Decimal

from validation import validate_order

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    logger.debug("Event: %s", json.dumps(event))
    body = event.get("body") or ""
    # API Gateway base64-encodes bodies it treats as binary; `sam local generate-event` does too.
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body)

    try:
        order = json.loads(body, parse_float=Decimal)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return response(400, {"errors": ["body is not valid JSON"]})

    errors = validate_order(order)
    if errors:
        logger.info("Rejected order: %s", errors)
        return response(400, {"errors": errors})

    logger.info("Accepted order %s", order["orderId"])
    return response(201, {"orderId": order["orderId"], "status": "ACCEPTED"})
