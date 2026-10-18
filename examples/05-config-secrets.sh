#!/usr/bin/env bash
# Secrets Manager and SSM Parameter Store: where an app reads its config and credentials.
source "$(dirname "$0")/_env.sh"

step "Read a JSON secret and pick out one field"
SECRET=$(aws secretsmanager get-secret-value --secret-id demo/db-credentials \
  --query SecretString --output text)
echo "$SECRET"
echo "username = $(jq -r .username <<< "$SECRET")"

step "Rotate it by writing a new version"
aws secretsmanager put-secret-value --secret-id demo/db-credentials \
  --secret-string '{"username": "app", "password": "rotated-local-password"}' \
  --query VersionId --output text
aws secretsmanager get-secret-value --secret-id demo/db-credentials \
  --query SecretString --output text

step "Load the whole /demo/config/ tree at once, decrypting SecureStrings"
aws ssm get-parameters-by-path --path /demo/config/ --with-decryption \
  --query 'Parameters[].{Name: Name, Type: Type, Value: Value}' --output table

step "Flip a feature flag"
aws ssm put-parameter --name /demo/config/new-checkout-enabled --value false --overwrite \
  --query Version --output text
aws ssm get-parameter --name /demo/config/new-checkout-enabled --query Parameter.Value --output text

# Put things back so the example can be re-run.
aws secretsmanager put-secret-value --secret-id demo/db-credentials \
  --secret-string '{"username": "app", "password": "local-dev-only"}' > /dev/null
aws ssm put-parameter --name /demo/config/new-checkout-enabled --value true --overwrite > /dev/null
