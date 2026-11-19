import { match } from "ts-pattern";
import { putOrder } from "../services/order-service.js";
import { logger } from "../lib/logger.js";

/** @returns {Promise<import("./types.js").OrderResult>} */
export async function createOrder(detail, meta) {
  const outcome = await putOrder(detail, meta);
  const ctx = { orderId: detail.orderId, idempotencyKey: detail.idempotencyKey, ...meta };

  return match(outcome)
    .with({ kind: "created" }, () => {
      logger.info("order created", ctx);
      return { statusCode: 201, body: { result: "created", orderId: detail.orderId } };
    })
    .with({ kind: "duplicate" }, () => {
      logger.info("duplicate event ignored", ctx);
      return { statusCode: 200, body: { result: "duplicate", orderId: detail.orderId } };
    })
    .with({ kind: "discarded" }, ({ existingKey }) => {
      logger.warn("create discarded: order was cancelled", { ...ctx, existingKey });
      return {
        statusCode: 409,
        body: { result: "discarded", message: "order was cancelled and cannot be created again", orderId: detail.orderId },
      };
    })
    .with({ kind: "conflict" }, ({ existingKey }) => {
      logger.warn("order already exists", { ...ctx, existingKey });
      return { statusCode: 409, body: { result: "conflict", message: "order already exists", orderId: detail.orderId } };
    })
    .exhaustive();
}
