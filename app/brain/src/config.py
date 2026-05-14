"""Configuration loaded from environment variables and Secrets Manager."""
import os
import json
import boto3
from functools import lru_cache

secrets_client = boto3.client(
    "secretsmanager",
    region_name=os.environ.get("AWS_REGION", "ca-central-1"),
)


@lru_cache(maxsize=1)
def get_db_credentials():
    secret_arn = os.environ["DB_SECRET_ARN"]
    resp = secrets_client.get_secret_value(SecretId=secret_arn)
    return json.loads(resp["SecretString"])


@lru_cache(maxsize=1)
def get_azure_openai_credentials():
    secret_arn = os.environ["AZURE_OPENAI_SECRET_ARN"]
    resp = secrets_client.get_secret_value(SecretId=secret_arn)
    return json.loads(resp["SecretString"])


# Plain env-var configuration. SQS_QUEUE_URL and S3_AUDIT_BUCKET use
# .get(..., "") for backwards compatibility with local/test runs - the
# Brain can boot without them and surface a clearer error later.
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
S3_AUDIT_BUCKET = os.environ.get("S3_AUDIT_BUCKET", "")

# AUDIT_KMS_KEY_ARN is required at import time. Fail-loud: the worker
# refuses to start if no KMS key is configured for audit-blob writes.
# This prevents the silent-fallback-to-aws/s3 bug where boto3's
# put_object with ServerSideEncryption='aws:kms' and no SSEKMSKeyId
# falls back to the AWS-managed default key. Audit writes are
# compliance-critical and must use the customer-managed key explicitly.
AUDIT_KMS_KEY_ARN = os.environ["AUDIT_KMS_KEY_ARN"]

ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
