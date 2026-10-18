# local-stack

A ready-to-use [LocalStack](https://localstack.cloud) setup on Docker Compose: AWS services
on `localhost:4566`, provisioned on startup with the resources of a small "orders" app,
plus runnable examples for each service and a Java SDK client.

## Requirements

- Docker with Compose v2
- AWS CLI v2 and `jq` (for the example scripts)
- Java 17+ and Maven (only for `java-client/`)
- A **LocalStack auth token** (free, see below)

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
S3 demo-bucket/incoming/*.json ──▶ Lambda order-processor ──▶ DynamoDB orders
                                             │
                                             ▼
                                  SNS order-events ──▶ SQS billing-queue  (all events)
                                                  └──▶ SQS shipping-queue (OrderPlaced only)

SQS orders-queue ──(2 failed receives)──▶ SQS orders-dlq
EventBridge demo-bus ──(rule: total >= 100)──▶ SQS order-audit-queue
Secrets Manager demo/db-credentials · SSM /demo/config/*
```

| Service         | Resource                                    | Notes                                                         |
|-----------------|---------------------------------------------|---------------------------------------------------------------|
| S3              | `demo-bucket`                               | `incoming/*.json` uploads trigger the Lambda                  |
| SQS             | `orders-queue`, `orders-dlq`                | redrive policy, `maxReceiveCount = 2`                         |
| SNS             | `order-events`                              | fans out to `billing-queue` and `shipping-queue` (filtered)   |
| DynamoDB        | `orders` (PK `orderId`)                     | GSI `customerId-index`                                        |
| Lambda          | `order-processor` (Python 3.13)             | source in `lambda/order_processor/handler.py`                 |
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
| `examples/07-lambda-pipeline.sh`  | S3 upload → Lambda → DynamoDB + SNS → SQS, Lambda logs, direct invoke   |
| `java-client/`                    | S3, SQS, DynamoDB, Secrets Manager and SSM through the Java SDK v2      |

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
- **Lambda stays `Pending` or fails to invoke:** Lambda functions run as sibling Docker
  containers, which needs `/var/run/docker.sock` mounted (already done in
  `docker-compose.yml`). The first start pulls the Python runtime image, so it takes longer.
- **Port 4566 already in use:** another LocalStack is probably running. Check with `docker ps`.
