import { match } from "ts-pattern";
import { ForbiddenError, isApiGateway, RouteNotFoundError, toCommand, UnauthorizedError } from "./events/parse.js";
import { createOrder } from "./events/create-order.js";
import { cancelOrder } from "./events/cancel-order.js";
import { ValidationError } from "./lib/validation.js";
import { logger } from "./lib/logger.js";
// Importing db/client (via the services) creates the DynamoDB client once,
// at cold start; every warm invocation reuses it and its connection pool.

/** API Gateway needs the proxy response format; EventBridge just gets an object. */
function respond(event, { statusCode, body }) {
  return isApiGateway(event)
    ? { statusCode, headers: { "content-type": "application/json" }, body: JSON.stringify(body) }
    : { statusCode, ...body };
}

export const handler = async (event, context) => {
  try {
    const { command, meta } = toCommand(event, context);

    const result = await match(command)
      .with({ type: "CreateOrder" }, ({ detail }) => createOrder(detail, meta))
      .with({ type: "CancelOrder" }, ({ detail }) => cancelOrder(detail, meta))
      .otherwise(({ type }) => {
        throw new RouteNotFoundError(`command ${type}`);
      });

    return respond(event, result);
  } catch (err) {
    // Client errors are returned, not thrown, so EventBridge does not retry them.
    if (err instanceof ValidationError) {
      logger.warn("validation failed", { errors: err.errors });
      return respond(event, { statusCode: 400, body: { result: "invalid", errors: err.errors } });
    }
    if (err instanceof UnauthorizedError) {
      logger.warn("request without authenticated customer");
      return respond(event, { statusCode: 401, body: { result: "unauthorized", message: err.message } });
    }
    if (err instanceof ForbiddenError) {
      logger.warn("forbidden", { message: err.message });
      return respond(event, { statusCode: 403, body: { result: "forbidden", message: err.message } });
    }
    if (err instanceof RouteNotFoundError) {
      logger.warn(err.message);
      return respond(event, { statusCode: 404, body: { result: "not_found", message: err.message } });
    }
    logger.error("unexpected error", { error: String(err) });
    // EventBridge: throw so the event is retried. API Gateway: 500.
    if (!isApiGateway(event)) throw err;
    return respond(event, { statusCode: 500, body: { result: "error", message: "internal error" } });
  }
};
