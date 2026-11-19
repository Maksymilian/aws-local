import { match } from "ts-pattern";
import { cancelOrderItem } from "../services/order-service.js";
import { logger } from "../lib/logger.js";

/** @returns {Promise<import("./types.js").OrderResult>} */
export async function cancelOrder(detail, meta) {
  const outcome = await cancelOrderItem(detail, meta);
  const ctx = { orderId: detail.orderId, idempotencyKey: detail.idempotencyKey, reason: detail.reason, ...meta };

  return match(outcome)
    .with({ kind: "cancelled" }, () => {
      logger.info("order cancelled", ctx);
      return { statusCode: 200, body: { result: "cancelled", orderId: detail.orderId } };
    })
    .with({ kind: "already_cancelled" }, () => {
      // A repeated cancel lands here, so it is not an error.
      logger.info("order already cancelled", ctx);
      return { statusCode: 200, body: { result: "already_cancelled", orderId: detail.orderId } };
    })
    .with({ kind: "not_found" }, () => {
      logger.warn("order not found, nothing to cancel", ctx);
      return { statusCode: 404, body: { result: "not_found", orderId: detail.orderId } };
    })
    .with({ kind: "forbidden" }, () => {
      logger.warn("cancel rejected: customer mismatch", ctx);
      return { statusCode: 403, body: { result: "forbidden", message: "order belongs to another customer" } };
    })
    .exhaustive();
}
