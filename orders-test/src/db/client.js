import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";
import { NodeHttpHandler } from "@smithy/node-http-handler";
import http from "node:http";
import https from "node:https";

// Created once per execution environment (module scope), during the init phase.
// Warm invocations reuse the client and its pooled keep-alive sockets, so they
// skip client construction, TLS handshakes and TCP setup.
const agentOptions = { keepAlive: true, maxSockets: 50 };

const endpoint = process.env.DYNAMODB_ENDPOINT || undefined; // "" -> real AWS

const client = new DynamoDBClient({
  region: process.env.AWS_REGION ?? "eu-central-1",
  endpoint,
  maxAttempts: 3,
  requestHandler: new NodeHttpHandler({
    // Local DynamoDB is plain HTTP, AWS is HTTPS: pool both.
    httpAgent: new http.Agent(agentOptions),
    httpsAgent: new https.Agent(agentOptions),
    connectionTimeout: 1_000,
    requestTimeout: 3_000,
  }),
});

// Document client: plain JS objects instead of { S: "..." } attribute maps.
export const ddb = DynamoDBDocumentClient.from(client, {
  marshallOptions: { removeUndefinedValues: true },
});

export const ORDERS_TABLE = process.env.ORDERS_TABLE ?? "orders-local";
