# aws-local

Run and test AWS services locally, with no AWS account:

- **LocalStack** on Docker Compose: AWS services on `localhost:4566`, provisioned on startup
  with the resources of a small "orders" app, plus runnable examples for each service and a
  Java SDK client.
- **`orders-test/`**: an orders Lambda (JavaScript) tested with the SAM CLI and DynamoDB Local,
  triggered both by EventBridge events and by a REST API behind API Gateway.

## Requirements

- Docker with Compose v2
- AWS CLI v2 and `jq` (for the example scripts)
- Java 17+ and Maven (only for `java-client/`)
- A **LocalStack auth token** (free, see below)
- For `orders-test/` only (it needs neither LocalStack nor the token):
  [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html),
  Node.js 22+, Go 1.24+, `jq` and `openssl`

### About the auth token

Since release 2026.03.0, LocalStack ships one unified image, and it won't start without an
auth token. The free **Hobby** plan (non-commercial use) covers everything used here: it
matches what the old Community image offered.

1. Sign up at [app.localstack.cloud](https://app.localstack.cloud) and copy your token from **Auth Tokens**.
2. `cp .env.example .env` and paste it into `LOCALSTACK_AUTH_TOKEN`.

`.env` is git-ignored. If you'd rather not sign up, set `LOCALSTACK_VERSION=4.14` to use the
last community image, which needs no token. It still works but no longer gets updates.

## Quick start

```bash
cp .env.example .env    # add your LOCALSTACK_AUTH_TOKEN
make up                 # starts LocalStack, waits until provisioning has finished
make examples           # runs every script in examples/
make java               # same idea through the AWS SDK for Java v2
make down               # stop and wipe everything
```

`make` with no target lists the rest (`logs`, `status`, `restart`).

## What gets provisioned

`init/ready.d/01-provision.sh` runs inside the container once LocalStack is up. The
container only reports *healthy* after the script succeeds, so `make up` (which runs
`docker compose up --wait`) returns once the resources below exist.

```
SNS order-events ──▶ SQS billing-queue  (all events)
                └──▶ SQS shipping-queue (OrderPlaced only)

SQS orders-queue ──(2 failed receives)──▶ SQS orders-dlq
EventBridge demo-bus ──(rule: total >= 100)──▶ SQS order-audit-queue
S3 demo-bucket · DynamoDB orders · Secrets Manager demo/db-credentials · SSM /demo/config/*
```

| Service         | Resource                                    | Notes                                                         |
|-----------------|---------------------------------------------|---------------------------------------------------------------|
| S3              | `demo-bucket`                               |                                                               |
| SQS             | `orders-queue`, `orders-dlq`                | redrive policy, `maxReceiveCount = 2`                         |
| SNS             | `order-events`                              | fans out to `billing-queue` and `shipping-queue` (filtered)   |
| DynamoDB        | `orders` (PK `orderId`)                     | GSI `customerId-index`                                        |
| EventBridge     | bus `demo-bus`, rule `high-value-orders`    | numeric content filter, targets `order-audit-queue`           |
| Secrets Manager | `demo/db-credentials`                       | JSON secret                                                   |
| SSM             | `/demo/config/{page-size,new-checkout-enabled,api-key}` | `api-key` is a `SecureString`                     |

State is kept in memory, so every restart starts clean and the init script runs again. To
add your own resources, drop another executable `*.sh` into `init/ready.d/`. Scripts run in
alphabetical order and can call `awslocal`, which is the AWS CLI already pointed at LocalStack.

## Examples

Each script is standalone and safe to re-run:

| Script                            | Shows                                                                   |
|-----------------------------------|-------------------------------------------------------------------------|
| `examples/01-s3.sh`               | upload with metadata, list, download, presigned URL fetched with `curl` |
| `examples/02-sqs.sh`              | send/receive/delete, poison message moved to the dead-letter queue      |
| `examples/03-sns-fanout.sh`       | one publish → two queues, subscription filter policy                    |
| `examples/04-dynamodb.sh`         | put/get, GSI query, conditional update (optimistic locking)             |
| `examples/05-config-secrets.sh`   | read/rotate a secret, load a parameter tree, flip a feature flag        |
| `examples/06-eventbridge.sh`      | content-based routing on a custom event bus                             |
| `java-client/`                    | S3, SQS, DynamoDB, Secrets Manager and SSM through the Java SDK v2      |

## orders-test: a Lambda tested locally with SAM

`orders-test/` needs no LocalStack, no auth token and no AWS account: the SAM CLI runs the
Lambda in the official runtime image, and DynamoDB Local stores the orders.

```
EventBridge  detail-type CreateOrder | CancelOrder ─┐
                                                    ├──▶ Lambda OrderFunction ──▶ DynamoDB orders-local
REST API     POST /orders                          ─┤        (one handler,        (DynamoDB Local,
             POST /orders/{orderId}/cancel         ─┘    pattern matching)          port 8000)
             └── Lambda authorizer (Bearer token)
```

- **One handler** (`src/handler.js`) for both triggers and both commands, routed with
  [ts-pattern](https://github.com/gvergnaud/ts-pattern). EventBridge `detail` and the REST body
  carry the same payload: `{"idempotencyKey": 1, "orderId": "order-001", "customerId": "cust-001", "amount": 149.99}`.
- **Idempotent**, one DynamoDB call per request:

  | Request | Result |
  |---|---|
  | new order | `201 created` |
  | same order, same `idempotencyKey` (a retry) | `200 duplicate` |
  | same order, new `idempotencyKey` | `409 conflict` |
  | cancel | `200 cancelled`: the item stays, with `status: CANCELLED` |
  | cancel again | `200 already_cancelled` |
  | create an order that was cancelled | `409 discarded` |
  | invalid payload | `400 invalid` |
  | someone else's order | `403 forbidden` |

- **Invocation metadata** is stored with every order, read from the real invocation, never
  from the payload: `source`, `requestId` (API request ID or EventBridge event ID), `clientIp`
  (REST only, EventBridge does not provide one), `userAgent`, `receivedAt`, `invocationId`, `invocation`.
- **Authentication** (REST only): a Lambda authorizer checks `Authorization: Bearer <token>`.
  The Lambda acts as the customer in the token, not the `customerId` in the body. Locally,
  `./make-token.sh cust-001` prints a token signed with the secret in `env.json`.

```bash
cd orders-test
npm install
docker compose up -d                 # DynamoDB Local + table orders-local

# The whole flow, step by step, with every response checked:
go run ./tools test eventbridge      # sam local invoke with events/*.json
go run ./tools test api              # sam local start-api on :3050, then curl
go run ./tools test api -step        # pause before each step

# Or by hand:
npm run build
sam local invoke OrderFunction -e events/01-create-order.json
sam local start-api                  # http://127.0.0.1:3050
curl -X POST http://127.0.0.1:3050/orders -H "Authorization: Bearer $(./make-token.sh cust-001)" \
  -d "$(jq -c .detail events/01-create-order.json)"
./show-table.sh                      # what is in DynamoDB
./clean-table.sh                     # remove every item

npm test                             # unit tests
```

Good to know:

- Your AWS profile is not used: the Go runner and the scripts pass dummy credentials, so an
  expired SSO session doesn't get in the way. By hand, `export AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local; unset AWS_PROFILE`.
- `samconfig.toml` holds **local-only** defaults: region, `env.json`, the `lambda-test` Docker
  network (so the Lambda reaches `dynamodb-local:8000`), port 3050, an x86_64 build and a public
  development `AuthSecret`. The secret and the architecture are set only for `sam build`,
  `sam local invoke` and `sam local start-api`, not in `[default.global.parameters]`, so
  `sam deploy` never picks them up.
- Deploying: the template has no default for `AuthSecret`, so pass a secure secret explicitly,
  e.g. `sam deploy --parameter-overrides AuthSecret=<value from Secrets Manager>`. Never reuse the
  development secret. Without the local override the functions build for arm64.
- `env.json` can only override variables that `template.yaml` declares.
- `./generate-events.sh` rewrites `events/*.json` from `sam local generate-event`.
- Locally, `sam local start-api` fills in placeholders: user agent `Custom User Agent String`,
  account `123456789012`, and it can repeat the same `requestId`. Real API Gateway sends real values.

## Using it from your own project

LocalStack speaks the real AWS APIs, so your code stays the same. Only the endpoint and
credentials change. Any access key works (`test` maps to account `000000000000`).

**AWS CLI / any SDK via environment variables.** This is what `examples/_env.sh` does:

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=eu-central-1 AWS_REGION=eu-central-1
aws s3 ls
```

**AWS SDK for Java v2.** See `java-client/src/main/java/com/example/localstack/AwsClients.java`:

```java
S3Client s3 = S3Client.builder()
        .endpointOverride(URI.create("http://localhost:4566"))
        .region(Region.EU_CENTRAL_1)
        .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create("test", "test")))
        .forcePathStyle(true)   // S3 only
        .build();
```

**Spring Boot with [Spring Cloud AWS](https://docs.awspring.io).** Put this in a `local` profile:

```yaml
spring:
  cloud:
    aws:
      endpoint: http://localhost:4566
      region.static: eu-central-1
      credentials:
        access-key: test
        secret-key: test
      s3.path-style-access-enabled: true
  config:
    import:
      - aws-secretsmanager:demo/db-credentials   # secret's JSON keys become properties
      - aws-parameterstore:/demo/config/         # page-size, new-checkout-enabled, api-key
```

**Integration tests.** [Testcontainers' LocalStack module](https://java.testcontainers.org/modules/localstack/)
starts a throwaway LocalStack per test run. Pass the same auth token through `LOCALSTACK_AUTH_TOKEN`.

## Handy endpoints

- `curl localhost:4566/_localstack/health`: which services are available or running
- `curl localhost:4566/_localstack/init/ready`: result of the init scripts
- [app.localstack.cloud](https://app.localstack.cloud) → Resource Browser: a web console for your local resources

## Troubleshooting

- **Container exits right after start with `License activation failed!`:** `LOCALSTACK_AUTH_TOKEN`
  is missing or invalid. Check `.env`.
- **`make up` reports the container unhealthy:** an init script failed. Run `make logs` and
  look for `Error while running script`.
- **Port 4566 already in use:** another LocalStack is probably running. Check with `docker ps`.
- **`orders-test`: port 3050 or 8000 already in use:** run the API on another port with
  `go run ./tools test api -port 3060`; for 8000, stop the other DynamoDB Local.
