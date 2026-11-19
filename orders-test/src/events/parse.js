import { match, P } from "ts-pattern";
import { validateCancel, validateCreate, ValidationError } from "../lib/validation.js";
import { extractInvocationMetadata } from "../lib/invocation-metadata.js";

/** @typedef {import("./types.js").OrderCommand} OrderCommand */
/** @typedef {import("../lib/invocation-metadata.js").InvocationMetadata} InvocationMetadata */

export class RouteNotFoundError extends Error {
  constructor(what) {
    super(`No route for ${what}`);
    this.name = "RouteNotFoundError";
  }
}

/** No authenticated identity on a REST request (authorizer missing or misconfigured). */
export class UnauthorizedError extends Error {
  constructor() {
    super("Unauthorized");
    this.name = "UnauthorizedError";
  }
}

/** The body names a different customer than the authenticated caller. */
export class ForbiddenError extends Error {
  constructor(message) {
    super(message);
    this.name = "ForbiddenError";
  }
}

/**
 * REST requests act as the customer the authorizer verified
 * (requestContext.authorizer.customerId), never as the customerId in the body.
 * A body customerId is optional; if present it must match the caller.
 */
function asAuthenticatedCustomer(e, body) {
  const customerId = e.requestContext?.authorizer?.customerId;
  if (typeof customerId !== "string" || customerId === "") throw new UnauthorizedError();
  if (body.customerId !== undefined && body.customerId !== customerId) {
    throw new ForbiddenError("customerId does not match the authenticated caller");
  }
  return { ...body, customerId };
}

export const isApiGateway = (e) =>
  typeof e === "object" && e !== null && "requestContext" in e && "httpMethod" in e;

function jsonBody(e) {
  const raw = e.isBase64Encoded ? Buffer.from(e.body ?? "", "base64").toString("utf8") : e.body ?? "";
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) return parsed;
  } catch {
    /* fall through */
  }
  throw new ValidationError(["body must be a JSON object"]);
}

/**
 * Turns any trigger into one command, using pattern matching on the event shape.
 *   EventBridge:  detail-type CreateOrder | CancelOrder
 *   REST API:     POST /orders                    -> CreateOrder
 *                 POST /orders/{orderId}/cancel   -> CancelOrder
 * The payload is validated here, so the business logic only sees checked data.
 * REST requests carry the caller's customerId from the authorizer (see asAuthenticatedCustomer).
 * @returns {{ command: OrderCommand, meta: InvocationMetadata }}
 */
export function toCommand(event, context) {
  const meta = extractInvocationMetadata(event, context);

  const command = match(event)
    // ---- EventBridge ----
    .with({ "detail-type": "CreateOrder" }, (e) => ({ type: "CreateOrder", detail: validateCreate(e.detail) }))
    .with({ "detail-type": "CancelOrder" }, (e) => ({ type: "CancelOrder", detail: validateCancel(e.detail) }))
    // ---- API Gateway REST ----
    .with({ httpMethod: "POST", resource: "/orders" }, (e) => ({
      type: "CreateOrder",
      detail: validateCreate(asAuthenticatedCustomer(e, jsonBody(e))),
    }))
    .with(
      { httpMethod: "POST", resource: "/orders/{orderId}/cancel", pathParameters: { orderId: P.string } },
      (e) => ({
        type: "CancelOrder",
        // orderId comes from the URL; a different one in the body is ignored.
        detail: validateCancel({ ...asAuthenticatedCustomer(e, jsonBody(e)), orderId: e.pathParameters.orderId }),
      }),
    )
    .otherwise((e) => {
      throw new RouteNotFoundError(
        isApiGateway(e) ? `${e.httpMethod} ${e.resource}` : `detail-type ${String(e?.["detail-type"])}`,
      );
    });

  return { command, meta };
}
