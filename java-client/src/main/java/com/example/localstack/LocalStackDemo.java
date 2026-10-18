package com.example.localstack;

import java.util.Map;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.Message;
import software.amazon.awssdk.services.ssm.SsmClient;

/** Uses the resources created by init/ready.d/01-provision.sh through plain AWS SDK calls. */
public final class LocalStackDemo {

    private static final String BUCKET = "demo-bucket";
    private static final String QUEUE = "orders-queue";
    private static final String TABLE = "orders";

    public static void main(String[] args) {
        try (S3Client s3 = AwsClients.s3();
             SqsClient sqs = AwsClients.sqs();
             DynamoDbClient dynamoDb = AwsClients.dynamoDb();
             SecretsManagerClient secrets = AwsClients.secretsManager();
             SsmClient ssm = AwsClients.ssm()) {
            s3(s3);
            sqs(sqs);
            dynamoDb(dynamoDb);
            config(secrets, ssm);
        }
    }

    private static void s3(S3Client s3) {
        section("S3");
        String key = "java-client/greeting.txt";
        s3.putObject(b -> b.bucket(BUCKET).key(key).contentType("text/plain"),
                RequestBody.fromString("Hello from the AWS SDK for Java"));
        String body = s3.getObjectAsBytes(b -> b.bucket(BUCKET).key(key)).asUtf8String();
        System.out.printf("s3://%s/%s -> %s%n", BUCKET, key, body);
        s3.deleteObject(b -> b.bucket(BUCKET).key(key));
    }

    private static void sqs(SqsClient sqs) {
        section("SQS");
        String queueUrl = sqs.getQueueUrl(b -> b.queueName(QUEUE)).queueUrl();
        sqs.sendMessage(b -> b.queueUrl(queueUrl).messageBody("{\"orderId\": \"o-java-1\"}"));

        for (Message message : sqs.receiveMessage(b -> b.queueUrl(queueUrl).waitTimeSeconds(2)).messages()) {
            System.out.println("received " + message.body());
            sqs.deleteMessage(b -> b.queueUrl(queueUrl).receiptHandle(message.receiptHandle()));
        }
    }

    private static void dynamoDb(DynamoDbClient dynamoDb) {
        section("DynamoDB");
        dynamoDb.putItem(b -> b.tableName(TABLE).item(Map.of(
                "orderId", AttributeValue.fromS("o-java-1"),
                "customerId", AttributeValue.fromS("c-java"),
                "total", AttributeValue.fromN("42.00"),
                "status", AttributeValue.fromS("PLACED"))));

        Map<String, AttributeValue> item = dynamoDb
                .getItem(b -> b.tableName(TABLE).key(Map.of("orderId", AttributeValue.fromS("o-java-1"))))
                .item();
        System.out.printf("order %s: status=%s total=%s%n",
                item.get("orderId").s(), item.get("status").s(), item.get("total").n());

        int count = dynamoDb.query(b -> b.tableName(TABLE)
                        .indexName("customerId-index")
                        .keyConditionExpression("customerId = :c")
                        .expressionAttributeValues(Map.of(":c", AttributeValue.fromS("c-java"))))
                .count();
        System.out.println("orders for c-java via GSI: " + count);
    }

    private static void config(SecretsManagerClient secrets, SsmClient ssm) {
        section("Secrets Manager + SSM Parameter Store");
        String secret = secrets.getSecretValue(b -> b.secretId("demo/db-credentials")).secretString();
        System.out.println("demo/db-credentials = " + secret);

        ssm.getParametersByPathPaginator(b -> b.path("/demo/config/").withDecryption(true))
                .stream()
                .flatMap(page -> page.parameters().stream())
                .forEach(p -> System.out.printf("%s = %s%n", p.name(), p.value()));
    }

    private static void section(String title) {
        System.out.printf("%n==> %s%n", title);
    }
}
