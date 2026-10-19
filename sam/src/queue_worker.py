"""Consumes order messages from SQS and reports partial batch failures.

With ReportBatchItemFailures on the event source mapping, returning the IDs
of the bad messages makes SQS retry (and eventually dead-letter) only those,
while the rest of the batch is deleted as processed.
"""
import json
import logging
import os
from decimal import Decimal

from validation import validate_order

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def handler(event, context):
    logger.debug("Event: %s", json.dumps(event))
    failures = []
    for record in event["Records"]:
        try:
            order = json.loads(record["body"], parse_float=Decimal)
        except json.JSONDecodeError:
            errors = ["body is not valid JSON"]
        else:
            errors = validate_order(order)

        if errors:
            logger.warning("Message %s failed: %s", record["messageId"], errors)
            failures.append({"itemIdentifier": record["messageId"]})
        else:
            logger.info("Processed order %s", order["orderId"])

    return {"batchItemFailures": failures}
