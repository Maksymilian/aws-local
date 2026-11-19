import { ConditionalCheckFailedException } from "@aws-sdk/client-dynamodb";
import { PutCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, ORDERS_TABLE } from "../db/client.js";

// Data access only: no knowledge of EventBridge, API Gateway or HTTP codes.
// Orders are never deleted: cancelling sets status CANCELLED and keeps the item.

/** Who did it and through what, from the real invocation. */
const auditFields = (meta) => ({
  source: meta.source,
  requestId: meta.requestId,
  clientIp: meta.clientIp,
  userAgent: meta.userAgent,
  receivedAt: meta.receivedAt,
  invocationId: meta.invocationId,
  functionArn: meta.functionArn,
  traceId: meta.traceId,
  invocation: meta.invocation,
});

/**
 * @returns {Promise<{kind:"created"} | {kind:"duplicate"} | {kind:"discarded", existingKey:number|null} | {kind:"conflict", existingKey:number|null}>}
 *   duplicate = same order, same idempotency key (a retry)
 *   discarded = the order was cancelled; it cannot be created again
 *   conflict  = the order exists (active) under a different key
 */
export async function putOrder(order, meta) {
  try {
    // One round trip: the condition makes the write idempotent and, on failure,
    // DynamoDB returns the existing item, so no extra GetItem is needed.
    await ddb.send(
      new PutCommand({
        TableName: ORDERS_TABLE,
        Item: {
          ...order,
          status: "CREATED",
          createdAt: new Date().toISOString(),
          ...auditFields(meta),
        },
        // Only brand-new orders. An orderId is never reused, even after cancelling.
        ConditionExpression: "attribute_not_exists(orderId)",
        ReturnValuesOnConditionCheckFailure: "ALL_OLD",
      }),
    );
    return { kind: "created" };
  } catch (err) {
    if (!(err instanceof ConditionalCheckFailedException)) throw err;
    // err.Item is the raw attribute map (not unmarshalled)
    const raw = err.Item?.idempotencyKey?.N;
    const existingKey = raw === undefined ? null : Number(raw);
    if (existingKey === order.idempotencyKey) return { kind: "duplicate" };
    if (err.Item?.status?.S === "CANCELLED") return { kind: "discarded", existingKey };
    return { kind: "conflict", existingKey };
  }
}

/**
 * Soft cancel: status -> CANCELLED, the item stays, with who/when/why cancelled.
 * @returns {Promise<{kind:"cancelled"} | {kind:"already_cancelled"} | {kind:"not_found"} | {kind:"forbidden"}>}
 *   forbidden = another customer's order
 */
export async function cancelOrderItem(cancel, meta) {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: ORDERS_TABLE,
        Key: { orderId: cancel.orderId },
        UpdateExpression:
          "SET #status = :cancelled, cancelledAt = :now, cancelReason = :reason, " +
          "cancelIdempotencyKey = :key, cancellation = :audit",
        ConditionExpression: "attribute_exists(orderId) AND customerId = :c AND #status <> :cancelled",
        ExpressionAttributeNames: { "#status": "status" },
        ExpressionAttributeValues: {
          ":cancelled": "CANCELLED",
          ":now": new Date().toISOString(),
          ":reason": cancel.reason ?? null,
          ":key": cancel.idempotencyKey,
          ":audit": auditFields(meta),
          ":c": cancel.customerId,
        },
        ReturnValuesOnConditionCheckFailure: "ALL_OLD",
      }),
    );
    return { kind: "cancelled" };
  } catch (err) {
    if (!(err instanceof ConditionalCheckFailedException)) throw err;
    const old = err.Item; // raw attribute map
    if (!old) return { kind: "not_found" };
    if (old.customerId?.S !== cancel.customerId) return { kind: "forbidden" };
    return { kind: "already_cancelled" };
  }
}
