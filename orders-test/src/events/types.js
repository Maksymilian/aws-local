// Shapes used across the Lambda, documented with JSDoc (no runtime code).

/**
 * @typedef {object} CreateOrderDetail
 * @property {number} idempotencyKey  sequence number, positive integer
 * @property {string} orderId
 * @property {string} customerId
 * @property {number} amount
 */

/**
 * @typedef {object} CancelOrderDetail
 * @property {number} idempotencyKey
 * @property {string} orderId
 * @property {string} customerId
 * @property {string} [reason]
 */

/**
 * Normalised command, independent of the trigger (EventBridge or REST API).
 * @typedef {{ type: "CreateOrder", detail: CreateOrderDetail }
 *         | { type: "CancelOrder", detail: CancelOrderDetail }} OrderCommand
 */

// Invocation metadata (source, requestId, clientIp, ...) is documented in lib/invocation-metadata.js.

/** @typedef {{ statusCode: number, body: Record<string, unknown> }} OrderResult */

export {};
