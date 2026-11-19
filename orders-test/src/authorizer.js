import { createHmac, timingSafeEqual } from "node:crypto";

// API Gateway TOKEN authorizer for the orders REST API.
//
// Token format (Authorization: Bearer <token>):
//   base64url(JSON {"sub": "<customerId>", "exp": <unix seconds>}) + "." + base64url(HMAC-SHA256(payload, AUTH_SECRET))
//
// This is a self-contained stand-in that also runs under `sam local start-api`.
// In production, prefer a Cognito user pool or JWT issuer and keep AUTH_SECRET in
// Secrets Manager / SSM, not in a plain environment variable.
//
// On success API Gateway caches the policy and passes `context.customerId` to the
// orders Lambda as event.requestContext.authorizer.customerId.

const SECRET = process.env.AUTH_SECRET ?? "";
const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

const sign = (payload) => createHmac("sha256", SECRET).update(payload).digest("base64url");

/** @returns {string | null} the customerId, or null when the token is not valid */
export function verifyToken(token, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (!SECRET || typeof token !== "string") return null;
  const [payload, sig, extra] = token.split(".");
  if (!payload || !sig || extra !== undefined) return null;

  const expected = Buffer.from(sign(payload));
  const given = Buffer.from(sig);
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;

  let claims;
  try {
    claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
  } catch {
    return null;
  }
  if (typeof claims?.sub !== "string" || !ID_PATTERN.test(claims.sub)) return null;
  if (!Number.isInteger(claims.exp) || claims.exp <= nowSeconds) return null;
  return claims.sub;
}

export const handler = async (event) => {
  const header = event.authorizationToken ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  const customerId = verifyToken(token);

  // Throwing exactly "Unauthorized" makes API Gateway answer 401.
  if (!customerId) throw new Error("Unauthorized");

  // Allow every method of this API stage, so the cached policy also covers
  // the other order routes for the same token.
  const [arnPrefix, stage] = event.methodArn.split("/");
  return {
    principalId: customerId,
    policyDocument: {
      Version: "2012-10-17",
      Statement: [{ Action: "execute-api:Invoke", Effect: "Allow", Resource: `${arnPrefix}/${stage}/*` }],
    },
    context: { customerId },
  };
};
