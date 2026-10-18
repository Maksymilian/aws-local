#!/usr/bin/env bash
# S3: upload, list, download, presigned URL, delete.
source "$(dirname "$0")/_env.sh"

BUCKET=demo-bucket
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

step "Upload a file with custom metadata"
echo "Hello from LocalStack at $(date -Iseconds)" > "$TMP/hello.txt"
aws s3 cp "$TMP/hello.txt" "s3://$BUCKET/docs/hello.txt" --metadata author=demo --no-progress

step "List objects under docs/"
aws s3 ls "s3://$BUCKET/docs/"

step "Read object metadata"
aws s3api head-object --bucket "$BUCKET" --key docs/hello.txt \
  --query '{ContentLength: ContentLength, ContentType: ContentType, Metadata: Metadata}'

step "Download it back"
aws s3 cp "s3://$BUCKET/docs/hello.txt" -

step "Generate a presigned URL and fetch it with plain curl (no AWS credentials)"
URL=$(aws s3 presign "s3://$BUCKET/docs/hello.txt" --expires-in 300)
echo "$URL"
curl -sf "$URL"

step "Delete it"
aws s3 rm "s3://$BUCKET/docs/hello.txt"
