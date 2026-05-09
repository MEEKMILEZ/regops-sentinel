"""Configuration loaded from environment variables and Secrets Manager."""
import os
import json
import boto3
from functools import lru_cache

secrets_client = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "ca-central-1"))


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


SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
S3_AUDIT_BUCKET = os.environ.get("S3_AUDIT_BUCKET", "")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")