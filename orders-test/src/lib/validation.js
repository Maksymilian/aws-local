// Hand-written validation: no schema library, so nothing extra to load at cold start.

/** @typedef {import("../events/types.js").CreateOrderDetail} CreateOrderDetail */
/** @typedef {import("../events/types.js").CancelOrderDetail} CancelOrderDetail */

export class ValidationError extends Error {
  /** @param {string[]} errors */
  constructor(errors) {
    super(`Invalid payload: ${errors.join("; ")}`);
    this.name = "ValidationError";
    this.errors = errors;
  }
}

const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

function checkIdempotencyKey(p, errors) {
  const k = p.idempotencyKey;
  if (typeof k !== "number" || !Number.isSafeInteger(k) || k < 1) {
    errors.push("idempotencyKey must be a positive integer");
  }
}

function checkId(p, field, errors) {
  const v = p[field];
  if (v === undefined || v === null || v === "") errors.push(`${field} is required`);
  else if (typeof v !== "string" || !ID_PATTERN.test(v)) {
    errors.push(`${field} must be 1-64 chars: letters, digits, '-' or '_'`);
  }
}

/**
 * True when n has at most 2 decimal places. Exact `n * 100 === Math.round(n * 100)`
 * fails for values like 0.29 (0.29 * 100 = 28.999999999999996), so the check
 * allows a tiny floating-point error; real extra digits (0.291 -> 29.1) are far larger.
 */
export function hasAtMostTwoDecimals(n) {
  const cents = n * 100;
  return Math.abs(cents - Math.round(cents)) < 1e-6;
}

function asObject(input) {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new ValidationError(["payload must be a JSON object"]);
  }
  return input;
}

/** @returns {CreateOrderDetail} */
export function validateCreate(input) {
  const p = asObject(input);
  const errors = [];
  checkIdempotencyKey(p, errors);
  checkId(p, "orderId", errors);
  checkId(p, "customerId", errors);
  const a = p.amount;
  if (typeof a !== "number" || !Number.isFinite(a) || a <= 0) {
    errors.push("amount must be a positive number");
  } else if (!hasAtMostTwoDecimals(a)) {
    errors.push("amount must have at most 2 decimal places");
  }
  if (errors.length) throw new ValidationError(errors);
  // Copy only known fields, so unexpected input never reaches DynamoDB.
  return { idempotencyKey: p.idempotencyKey, orderId: p.orderId, customerId: p.customerId, amount: a };
}

/** @returns {CancelOrderDetail} */
export function validateCancel(input) {
  const p = asObject(input);
  const errors = [];
  checkIdempotencyKey(p, errors);
  checkId(p, "orderId", errors);
  checkId(p, "customerId", errors);
  if (p.reason !== undefined && (typeof p.reason !== "string" || p.reason.length > 500)) {
    errors.push("reason must be a string of at most 500 chars");
  }
  if (errors.length) throw new ValidationError(errors);
  return { idempotencyKey: p.idempotencyKey, orderId: p.orderId, customerId: p.customerId, reason: p.reason };
}
