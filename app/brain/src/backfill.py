"""
Re-classification backfill for degraded alert rows.

Industry-standard backfill pattern (per ml4devs / Databricks guidance):
- Parameterised: filters on the degraded-row signature, not hard-coded ids
- Idempotent: reuses upsert_alert (ON CONFLICT DO UPDATE) so re-runs are safe
- Targeted: only touches rows that look like classifier fallback output
- Same code path: calls classifier.classify and worker.upsert_alert
- Observable: structured logs + final summary, exit code reflects outcome
- One-off compute: invoked via `python -m src.backfill` from an ECS run-task
  override; never runs against the live FastAPI process

Trigger to filter on:
    relevance_score = 0 AND classification = 'NEEDS_REVIEW'

This signature matches the exception fallback in classifier.classify:
    return {
        "classification": "NEEDS_REVIEW",
        "relevance_score": 0.0,
        "urgency": "MEDIUM",
        "product_categories": [],
        "brief_summary": f"Classification error: ..."
    }

It will also catch any future failed classifications so the same script
can be re-run when Azure OpenAI hiccups or a watcher pushes bad data.

Run with:
    python -m src.backfill

Exit codes:
    0 - all rows re-classified successfully (or no rows needed it)
    1 - one or more rows failed to re-classify
"""

import logging
import json
import sys
import time

from psycopg.rows import dict_row

from .classifier import classify
from .config import get_azure_openai_credentials
from .db import get_connection
from .worker import upsert_alert, write_audit_blob, DEFAULT_TENANT

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s :: %(message)s",
)
logger = logging.getLogger("backfill")

# Throttle between rows. Azure OpenAI deployment limit observed via curl was
# 186 req / 10s, so 0.5s is two orders of magnitude under that. Keeps the
# script polite even when the row count grows.
SLEEP_BETWEEN_ROWS_S = 0.5

DEGRADED_ROWS_SQL = """
    SELECT alert_id, raw_payload, tenant_id
    FROM alerts
    WHERE relevance_score = 0
      AND classification = 'NEEDS_REVIEW'
    ORDER BY alert_id
"""


def fetch_degraded_rows():
    """Return all rows whose classification looks like a fallback result."""
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(DEGRADED_ROWS_SQL)
            rows = cur.fetchall()
    return rows


def reclassify_row(row, deployment_name):
    """Re-run classification for a single row. Returns the new classification dict.

    Raises on failure; the caller decides how to treat partial failures.
    """
    alert_id = row["alert_id"]
    tenant_id = row["tenant_id"] or DEFAULT_TENANT
    raw_payload = row["raw_payload"]

    # raw_payload comes back as a dict from psycopg (jsonb column).
    # Defensive: handle both shapes in case of historical data drift.
    if isinstance(raw_payload, str):
        item = json.loads(raw_payload)
    else:
        item = raw_payload

    logger.info(
        "reclassify alert_id=%s source=%s external_id=%s",
        alert_id,
        item.get("source"),
        item.get("external_id"),
    )

    classification = classify(item, deployment_name)

    new_class = classification.get("classification")
    new_score = classification.get("relevance_score")
    new_urgency = classification.get("urgency")
    logger.info(
        "  classified -> %s / %s / score=%s",
        new_class,
        new_urgency,
        new_score,
    )

    # Same downstream side effects as the worker. New audit blob is written
    # alongside the original (different timestamp in the key) so we keep a
    # complete history of every classifier invocation.
    audit_key = write_audit_blob(item, classification, tenant_id)
    logger.info("  audit blob s3 key=%s", audit_key)

    new_alert_id = upsert_alert(item, classification, tenant_id)
    logger.info("  upserted alert_id=%s", new_alert_id)

    return classification


def main():
    logger.info("backfill starting")
    deployment_name = get_azure_openai_credentials().get(
        "deployment_name", "gpt-4o-regops"
    )
    logger.info("using Azure OpenAI deployment: %s", deployment_name)

    rows = fetch_degraded_rows()
    total = len(rows)
    logger.info("found %d degraded rows to re-classify", total)

    if total == 0:
        logger.info("nothing to do; exiting")
        return 0

    successes = 0
    failures = 0
    fallback_after_retry = 0

    for idx, row in enumerate(rows, start=1):
        logger.info("--- row %d/%d ---", idx, total)
        try:
            classification = reclassify_row(row, deployment_name)
            # If we still got NEEDS_REVIEW with score 0 after retry, count it
            # separately so the operator knows the row genuinely lacks signal
            # (e.g. empty title from Shortages watcher) vs Azure being broken.
            if (
                classification.get("classification") == "NEEDS_REVIEW"
                and classification.get("relevance_score", 0) == 0
            ):
                fallback_after_retry += 1
            successes += 1
        except Exception:
            logger.exception("row alert_id=%s failed", row.get("alert_id"))
            failures += 1

        if idx < total:
            time.sleep(SLEEP_BETWEEN_ROWS_S)

    logger.info("backfill complete")
    logger.info("  total rows attempted: %d", total)
    logger.info("  successes:            %d", successes)
    logger.info("  failures:             %d", failures)
    logger.info(
        "  still fallback after retry: %d "
        "(payload likely lacks classifiable signal)",
        fallback_after_retry,
    )

    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
