"""SQS message processor. Polls queue, classifies items, writes to RDS + S3."""
import json
import logging
import os
import time
import boto3
from datetime import datetime, timezone
from .config import (
    SQS_QUEUE_URL,
    S3_AUDIT_BUCKET,
    AUDIT_KMS_KEY_ARN,
    get_azure_openai_credentials,
)
from .db import get_connection
from .classifier import classify

logger = logging.getLogger(__name__)

sqs = boto3.client("sqs", region_name=os.environ.get("AWS_REGION", "ca-central-1"))
s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "ca-central-1"))

DEFAULT_TENANT = "tenant-acme-meddev"


def write_audit_blob(item: dict, classification: dict, tenant_id: str):
    """Write the audit blob for one classification, explicitly encrypted
    with the customer-managed KMS key.

    Why we pass SSEKMSKeyId explicitly:
    Boto3's put_object accepts ServerSideEncryption='aws:kms' without
    SSEKMSKeyId, but in that case S3 falls back to the AWS-managed
    'aws/s3' alias - not the bucket's default customer-managed key.
    That fallback is silent and bypasses the bucket's encryption
    policy. Passing SSEKMSKeyId here removes any ambiguity: the worker
    declares which key it uses for every write. If the env var is
    missing the worker fails to import (see config.py), which is the
    correct fail-loud behaviour for a compliance-critical write path.
    """
    timestamp = datetime.now(timezone.utc)
    key = (
        f"audit/{tenant_id}/"
        f"{timestamp.strftime('%Y/%m/%d')}/"
        f"{item.get('source', 'unknown')}_{item.get('external_id', 'noid')}_{int(timestamp.timestamp())}.json"
    )
    payload = {
        "tenant_id": tenant_id,
        "audit_timestamp": timestamp.isoformat(),
        "source_item": item,
        "classification": classification
    }
    s3.put_object(
        Bucket=S3_AUDIT_BUCKET,
        Key=key,
        Body=json.dumps(payload).encode("utf-8"),
        ContentType="application/json",
        ServerSideEncryption="aws:kms",
        SSEKMSKeyId=AUDIT_KMS_KEY_ARN,
    )
    return key


def upsert_alert(item: dict, classification: dict, tenant_id: str):
    sql = """
        INSERT INTO alerts (
            tenant_id, source, external_id, title, summary, url,
            classification, relevance_score, urgency, product_categories,
            raw_payload, fetched_at
        )
        VALUES (
            %(tenant_id)s, %(source)s, %(external_id)s, %(title)s, %(summary)s, %(url)s,
            %(classification)s, %(relevance_score)s, %(urgency)s, %(product_categories)s,
            %(raw_payload)s, %(fetched_at)s
        )
        ON CONFLICT (tenant_id, source, external_id) DO UPDATE SET
            title              = EXCLUDED.title,
            summary            = EXCLUDED.summary,
            url                = EXCLUDED.url,
            classification     = EXCLUDED.classification,
            relevance_score    = EXCLUDED.relevance_score,
            urgency            = EXCLUDED.urgency,
            product_categories = EXCLUDED.product_categories,
            raw_payload        = EXCLUDED.raw_payload,
            classified_at      = NOW()
        RETURNING alert_id
    """
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, {
                "tenant_id": tenant_id,
                "source": item.get("source"),
                "external_id": str(item.get("external_id", "")),
                "title": item.get("title", ""),
                "summary": classification.get("brief_summary", ""),
                "url": item.get("url", ""),
                "classification": classification.get("classification", "NEEDS_REVIEW"),
                "relevance_score": classification.get("relevance_score", 0.0),
                "urgency": classification.get("urgency", "MEDIUM"),
                "product_categories": classification.get("product_categories", []),
                "raw_payload": json.dumps(item),
                "fetched_at": item.get("fetched_at")
            })
            alert_id = cur.fetchone()["alert_id"]
        conn.commit()
    return alert_id


def process_message(message: dict, deployment_name: str):
    body = json.loads(message["Body"])
    logger.info(f"Processing item {body.get('source')}/{body.get('external_id')}")

    classification = classify(body, deployment_name)
    logger.info(f"Classification: {classification.get('classification')} urgency={classification.get('urgency')}")

    tenant_id = DEFAULT_TENANT

    audit_key = write_audit_blob(body, classification, tenant_id)
    logger.info(f"Audit blob written: s3://{S3_AUDIT_BUCKET}/{audit_key}")

    alert_id = upsert_alert(body, classification, tenant_id)
    logger.info(f"Alert upserted: alert_id={alert_id}")

    return alert_id


def poll_loop():
    logger.info(f"Worker starting. Queue: {SQS_QUEUE_URL}")
    deployment_name = get_azure_openai_credentials().get("deployment_name", "gpt-4o-regops")

    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=5,
                WaitTimeSeconds=20,
                VisibilityTimeout=300
            )
            messages = response.get("Messages", [])
            if not messages:
                continue

            logger.info(f"Received {len(messages)} messages")
            for msg in messages:
                try:
                    process_message(msg, deployment_name)
                    sqs.delete_message(
                        QueueUrl=SQS_QUEUE_URL,
                        ReceiptHandle=msg["ReceiptHandle"]
                    )
                except Exception as e:
                    logger.exception(f"Failed to process message: {e}")
        except Exception as e:
            logger.exception(f"Poll loop error: {e}")
            time.sleep(5)
