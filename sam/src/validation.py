"""Order validation shared by create_order.py and queue_worker.py.

Pure Python with no AWS calls, which is what lets the functions run under
`sam local` with nothing else around them.
"""
import os
from decimal import Decimal

MAX_ORDER_TOTAL = Decimal(os.environ.get("MAX_ORDER_TOTAL", "10000"))


def validate_order(order) -> list[str]:
    """Return what is wrong with the order. An empty list means it's valid.

    Parse the JSON with parse_float=Decimal so totals keep their exact value.
    """
    if not isinstance(order, dict):
        return ["order must be a JSON object"]

    errors = []
    for field in ("orderId", "customerId"):
        value = order.get(field)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{field} must be a non-empty string")

    items = order.get("items")
    if not isinstance(items, list) or not items:
        errors.append("items must be a non-empty list")
    else:
        for i, item in enumerate(items):
            item = item if isinstance(item, dict) else {}
            if not isinstance(item.get("sku"), str) or not item["sku"]:
                errors.append(f"items[{i}].sku must be a non-empty string")
            qty = item.get("qty")
            if type(qty) is not int or qty < 1:  # type() check so that true isn't taken as 1
                errors.append(f"items[{i}].qty must be a positive integer")

    total = order.get("total")
    if type(total) not in (int, Decimal) or total < 0:
        errors.append("total must be a non-negative number")
    elif total > MAX_ORDER_TOTAL:
        errors.append(f"total {total} exceeds the limit of {MAX_ORDER_TOTAL}")

    return errors
