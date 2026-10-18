package com.example.localstack;

import java.net.URI;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.awscore.client.builder.AwsClientBuilder;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.ssm.SsmClient;

/**
 * The only LocalStack-specific code: every client gets the same endpoint override,
 * region and dummy credentials. In a real project this lives behind a "local"
 * profile; against real AWS you drop the override and use the default credentials chain.
 */
final class AwsClients {

    private static final URI ENDPOINT = URI.create(env("AWS_ENDPOINT_URL", "http://localhost:4566"));
    private static final Region REGION = Region.of(env("AWS_REGION", "eu-central-1"));
    private static final AwsCredentialsProvider CREDENTIALS =
            StaticCredentialsProvider.create(AwsBasicCredentials.create("test", "test"));

    private AwsClients() {
    }

    static S3Client s3() {
        // Path-style URLs (localhost:4566/bucket/key) don't rely on DNS for bucket.localhost.
        return local(S3Client.builder().forcePathStyle(true));
    }

    static SqsClient sqs() {
        return local(SqsClient.builder());
    }

    static DynamoDbClient dynamoDb() {
        return local(DynamoDbClient.builder());
    }

    static SecretsManagerClient secretsManager() {
        return local(SecretsManagerClient.builder());
    }

    static SsmClient ssm() {
        return local(SsmClient.builder());
    }

    private static <B extends AwsClientBuilder<B, C>, C> C local(B builder) {
        return builder.endpointOverride(ENDPOINT)
                .region(REGION)
                .credentialsProvider(CREDENTIALS)
                .build();
    }

    private static String env(String name, String fallback) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? fallback : value;
    }
}
