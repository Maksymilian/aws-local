import { test } from "node:test";
import assert from "node:assert/strict";
import { hasAtMostTwoDecimals, validateCreate, ValidationError } from "./validation.js";

const order = (amount) => ({ idempotencyKey: 1, orderId: "order-001", customerId: "cust-001", amount });

test("amounts with up to 2 decimals are accepted", () => {
  for (const amount of [0.29, 0.25, 0.1, 0.07, 1, 19.9, 149.99, 1234567.89]) {
    assert.equal(hasAtMostTwoDecimals(amount), true, `${amount}`);
    assert.equal(validateCreate(order(amount)).amount, amount);
  }
});

test("amounts with more than 2 decimals are rejected", () => {
  for (const amount of [0.291, 0.001, 1.005, 149.999]) {
    assert.equal(hasAtMostTwoDecimals(amount), false, `${amount}`);
    assert.throws(() => validateCreate(order(amount)), (err) => {
      assert.ok(err instanceof ValidationError);
      assert.deepEqual(err.errors, ["amount must have at most 2 decimal places"]);
      return true;
    });
  }
});

test("non-positive amounts are rejected", () => {
  for (const amount of [0, -1, Number.NaN, "10"]) {
    assert.throws(() => validateCreate(order(amount)), ValidationError);
  }
});
