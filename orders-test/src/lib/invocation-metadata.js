import { isIP } from "node:net";

/**
 * Who invoked the Lambda and through what, read only from the real invocation
 * (the event envelope and the Lambda context), never from the business payload.
 *
 *   field        REST API (v1)                         EventBridge
 *   source       "api-gateway-rest"                    "eventbridge"
 *   requestId    requestContext.requestId              id (event ID)
 *   clientIp     requestContext.identity.sourceIp      not provided -> null
 *   userAgent    requestContext.identity.userAgent     not provided -> null
 *   receivedAt   requestContext.requestTimeEpoch       time
 *   invocation   apiId, stage, httpMethod, path,       eventSource, detailType,
 *                extendedRequestId, accountId          account, region, resources
 *
 * HTTP API (v2) and Function URLs are recognised too (requestContext.http.*).
 *
 * Always, from the Lambda runtime:
 *   invocationId   context.awsRequestId   (find the run in CloudWatch Logs)
 *   functionArn    context.invokedFunctionArn
 *   traceId        Root=... from _X_AMZN_TRACE_ID (X-Ray), when tracing is on
 *
 * @typedef {"eventbridge" | "api-gateway-rest" | "api-gateway-http" | "lambda-function-url" | "unknown"} InvocationSource
 * @typedef {object} InvocationMetadata
 * @property {InvocationSource} source
 * @property {string | null} requestId
 * @property {string | null} clientIp
 * @property {string | null} userAgent
 * @property {string | null} receivedAt   ISO time the request/event entered AWS
 * @property {string} invocationId
 * @property {string | null} functionArn
 * @property {string | null} traceId
 * @property {Record<string, unknown>} invocation  source-specific details
 */

const str = (v, max = 512) => (typeof v === "string" && v !== "" ? v.slice(0, max) : null);
const ip = (v) => (typeof v === "string" && isIP(v) ? v : null);
const isoFromEpochMs = (v) => (Number.isFinite(v) ? new Date(v).toISOString() : null);

/** @returns {InvocationSource} */
export function invocationSource(event) {
  const rc = event?.requestContext;
  if (event?.["detail-type"] && event?.source && event?.id) return "eventbridge";
  if (event?.version === "2.0" && rc?.http) {
    return rc.domainName?.includes(".lambda-url.") ? "lambda-function-url" : "api-gateway-http";
  }
  if (rc?.identity && event?.httpMethod) return "api-gateway-rest";
  return "unknown";
}

function traceId() {
  return (process.env._X_AMZN_TRACE_ID ?? "").match(/(?:^|;)Root=([^;]+)/)?.[1] ?? null;
}

/** @returns {InvocationMetadata} */
export function extractInvocationMetadata(event, context) {
  const source = invocationSource(event);
  const rc = event?.requestContext;
  const runtime = {
    invocationId: context.awsRequestId,
    functionArn: str(context.invokedFunctionArn),
    traceId: traceId(),
  };

  if (source === "eventbridge") {
    // EventBridge does not record who called PutEvents: no client IP or user agent.
    return {
      source,
      requestId: str(event.id),
      clientIp: null,
      userAgent: null,
      receivedAt: str(event.time),
      ...runtime,
      invocation: {
        eventSource: str(event.source),
        detailType: str(event["detail-type"]),
        account: str(event.account),
        region: str(event.region),
        resources: Array.isArray(event.resources) ? event.resources.slice(0, 20) : [],
      },
    };
  }

  const http = rc?.http; // HTTP API v2 / Function URL
  return {
    source,
    requestId: str(rc?.requestId),
    // As seen by API Gateway on the TCP connection, not the spoofable X-Forwarded-For header.
    clientIp: ip(http?.sourceIp ?? rc?.identity?.sourceIp),
    userAgent: str(http?.userAgent ?? rc?.identity?.userAgent),
    receivedAt: isoFromEpochMs(rc?.timeEpoch ?? rc?.requestTimeEpoch),
    ...runtime,
    invocation: {
      apiId: str(rc?.apiId),
      stage: str(rc?.stage),
      httpMethod: str(http?.method ?? event?.httpMethod),
      path: str(http?.path ?? event?.path),
      route: str(event?.routeKey ?? event?.resource),
      extendedRequestId: str(rc?.extendedRequestId),
      accountId: str(rc?.accountId),
    },
  };
}
