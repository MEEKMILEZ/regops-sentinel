"""Async CSV ingestion for the devices catalog (Phase 5B.2).

Industry-standard async job pattern:
  - POST /devices/upload creates a job row (status=queued) and kicks off
    a background thread.
  - GET /devices/upload/{job_id} returns the current job state for the
    UI to poll.
  - The worker thread parses the CSV, validates and UPSERTs rows in
    batches, and updates the job row's counts as it progresses.

CSV format matches Health Canada MDALL (Medical Device Active Licence
Listing) public exports, the actual file format a Canadian distributor
would have on hand. Column mapping documented in `MDALL_COLUMN_MAP`.
"""

from __future__ import annotations

import csv
import io
import json
import logging
import threading
import time
from typing import Optional
from uuid import UUID

from psycopg.rows import dict_row

from .db import get_connection

logger = logging.getLogger(__name__)

# Map MDALL CSV column names -> our devices table columns.
# These match the publicly documented MDALL field names that Health
# Canada uses in MDALL/CSV exports.
# https://hc-sc.gc.ca/dhp-mps/prodpharma/databasdon/index-eng.php
MDALL_COLUMN_MAP = {
    "LICENCE_NO": "mdl_number",
    "DEVICE_NAME": "brand_name",
    "MODEL_IDENTIFIER": "model_number",
    "COMPANY_NAME": "manufacturer",
    "DEVICE_CLASS": "device_class",
    "LICENCE_STATUS": "status",
    "UDI_DI": "di",
}

# Health Canada licence_status -> our internal status enum.
# Real MDALL exports have a richer set; we map to the subset our table
# supports.
STATUS_MAP = {
    "ACTIVE": "active",
    "CANCELLED": "discontinued",
    "EXPIRED": "discontinued",
    "SUSPENDED": "recalled",
    "FAWAITING": "pending",
    "PENDING": "pending",
}

# Process this many rows between job-row status updates. Lower = more
# granular progress for the UI, higher = less DB chatter. 5 is a good
# balance for our expected file sizes (10-200 rows).
BATCH_SIZE = 5


def _validate_row(
    raw_row: dict,
    row_number: int,
) -> tuple[Optional[dict], Optional[str]]:
    """Map MDALL row to our internal shape, validating required fields.

    Returns (mapped_dict, None) on success or (None, error_message)
    on validation failure.
    """
    # Strip whitespace from all values up front; MDALL exports often
    # have padding.
    stripped = {k: (v or "").strip() for k, v in raw_row.items()}

    di = stripped.get("UDI_DI") or stripped.get("LICENCE_NO") or ""
    brand_name = stripped.get("DEVICE_NAME") or ""
    manufacturer = stripped.get("COMPANY_NAME") or ""
    device_class_raw = stripped.get("DEVICE_CLASS") or ""

    # Required fields
    if not di:
        return None, "missing required field: UDI_DI or LICENCE_NO"
    if not brand_name:
        return None, "missing required field: DEVICE_NAME"
    if not manufacturer:
        return None, "missing required field: COMPANY_NAME"
    if not device_class_raw:
        return None, "missing required field: DEVICE_CLASS"

    # Normalise device_class to our enum (I, II, III, IV).
    # MDALL uses Roman numerals already, but defensively handle stray
    # casing/whitespace.
    device_class = device_class_raw.upper().strip()
    if device_class not in ("I", "II", "III", "IV"):
        return None, f"invalid DEVICE_CLASS: {device_class_raw!r}"

    # Map licence_status -> our status enum, defaulting to active.
    status_raw = (stripped.get("LICENCE_STATUS") or "ACTIVE").upper()
    status = STATUS_MAP.get(status_raw, "active")

    return {
        "di": di,
        "brand_name": brand_name,
        "model_number": stripped.get("MODEL_IDENTIFIER") or None,
        "manufacturer": manufacturer,
        "mdl_number": stripped.get("LICENCE_NO") or None,
        "device_class": device_class,
        "status": status,
        # Clearance type is not part of MDALL; default to MDL since this
        # is a Canadian licensing file.
        "clearance_type": "MDL",
    }, None


def _process_job(job_id: str, tenant_id: str, payload_csv: str) -> None:
    """Run the actual CSV processing for a job. Runs in a worker thread.

    Updates the job row's counters as it goes so the UI can poll for
    progress. On any unrecoverable exception, marks the job as failed
    with the exception message in failure_reason.
    """
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE device_upload_jobs SET status = 'processing', started_at = NOW() WHERE job_id = %s",
                    (job_id,),
                )
            conn.commit()

        # Parse the CSV in one pass to count total rows (so the UI can
        # render a useful progress bar from row 1, not "loading..."
        # until the file is fully consumed).
        reader = csv.DictReader(io.StringIO(payload_csv))
        rows = list(reader)
        total = len(rows)

        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE device_upload_jobs SET total_rows = %s WHERE job_id = %s",
                    (total, job_id),
                )
            conn.commit()

        inserted = 0
        updated = 0
        errors = 0
        error_log: list[dict] = []

        for batch_start in range(0, total, BATCH_SIZE):
            batch = rows[batch_start:batch_start + BATCH_SIZE]
            batch_inserted = 0
            batch_updated = 0
            batch_errors = 0

            with get_connection() as conn:
                with conn.cursor(row_factory=dict_row) as cur:
                    for offset, raw_row in enumerate(batch):
                        row_number = batch_start + offset + 1  # 1-indexed
                        mapped, err = _validate_row(raw_row, row_number)
                        if err is not None:
                            batch_errors += 1
                            if len(error_log) < 50:
                                # Cap stored errors at 50 to bound memory;
                                # error_count keeps the true total.
                                error_log.append({
                                    "row": row_number,
                                    "di": raw_row.get("UDI_DI") or raw_row.get("LICENCE_NO"),
                                    "error": err,
                                })
                            continue

                        # UPSERT - if (tenant_id, di) exists, update;
                        # otherwise insert. Updates always bump updated_at.
                        # RETURNING xmax = 0 lets us tell apart inserts
                        # (xmax = 0) from updates (xmax != 0).
                        try:
                            cur.execute(
                                """
                                INSERT INTO devices (
                                    tenant_id, di, brand_name, model_number,
                                    manufacturer, mdl_number, device_class,
                                    status, clearance_type
                                )
                                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                                ON CONFLICT (tenant_id, di) DO UPDATE SET
                                    brand_name     = EXCLUDED.brand_name,
                                    model_number   = EXCLUDED.model_number,
                                    manufacturer   = EXCLUDED.manufacturer,
                                    mdl_number     = EXCLUDED.mdl_number,
                                    device_class   = EXCLUDED.device_class,
                                    status         = EXCLUDED.status,
                                    clearance_type = EXCLUDED.clearance_type,
                                    updated_at     = NOW()
                                RETURNING (xmax = 0) AS inserted
                                """,
                                (
                                    tenant_id, mapped["di"], mapped["brand_name"],
                                    mapped["model_number"], mapped["manufacturer"],
                                    mapped["mdl_number"], mapped["device_class"],
                                    mapped["status"], mapped["clearance_type"],
                                ),
                            )
                            result = cur.fetchone()
                            if result and result["inserted"]:
                                batch_inserted += 1
                            else:
                                batch_updated += 1
                        except Exception as row_exc:
                            batch_errors += 1
                            if len(error_log) < 50:
                                error_log.append({
                                    "row": row_number,
                                    "di": mapped["di"],
                                    "error": f"db error: {row_exc}",
                                })
                conn.commit()

            inserted += batch_inserted
            updated += batch_updated
            errors += batch_errors
            processed = batch_start + len(batch)

            # Update job progress after each batch
            with get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        UPDATE device_upload_jobs
                        SET processed_rows = %s,
                            inserted_count = %s,
                            updated_count = %s,
                            error_count = %s,
                            error_log = %s
                        WHERE job_id = %s
                        """,
                        (
                            processed, inserted, updated, errors,
                            json.dumps(error_log), job_id,
                        ),
                    )
                conn.commit()

        # Done.
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE device_upload_jobs SET status = 'complete', completed_at = NOW() WHERE job_id = %s",
                    (job_id,),
                )
            conn.commit()
        logger.info(
            "device upload job %s complete: %d inserted, %d updated, %d errors",
            job_id, inserted, updated, errors,
        )
    except Exception as e:
        logger.exception("device upload job %s failed", job_id)
        try:
            with get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        UPDATE device_upload_jobs
                        SET status = 'failed',
                            failure_reason = %s,
                            completed_at = NOW()
                        WHERE job_id = %s
                        """,
                        (str(e), job_id),
                    )
                conn.commit()
        except Exception:
            logger.exception("could not mark job %s as failed", job_id)


def create_upload_job(
    tenant_id: str,
    payload_csv: str,
    filename: Optional[str] = None,
) -> str:
    """Insert a queued job row and start the background worker.

    Returns the job_id as a string. The worker thread is a daemon so
    it dies with the process; in a real production deployment this
    would be a separate worker service consuming from SQS, but a
    daemon thread is the appropriate scale for our portfolio demo.
    """
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                INSERT INTO device_upload_jobs (tenant_id, filename, payload_csv)
                VALUES (%s, %s, %s)
                RETURNING job_id
                """,
                (tenant_id, filename, payload_csv),
            )
            row = cur.fetchone()
            job_id = str(row["job_id"])
        conn.commit()

    # Start the worker thread (daemon=True so it doesn't block process
    # exit). For production scale, replace this with an SQS consumer
    # or a Celery/RQ worker.
    thread = threading.Thread(
        target=_process_job,
        args=(job_id, tenant_id, payload_csv),
        daemon=True,
        name=f"device-upload-{job_id[:8]}",
    )
    thread.start()
    logger.info("queued device upload job %s for tenant %s", job_id, tenant_id)
    return job_id


def get_upload_job(tenant_id: str, job_id: str) -> Optional[dict]:
    """Return the current state of a job, scoped to the caller's tenant.

    Cross-tenant lookups return None (caller maps to 404).
    """
    # Validate that job_id is a real UUID before querying so we don't
    # leak a syntax error to the caller.
    try:
        UUID(job_id)
    except ValueError:
        return None

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT
                    job_id, tenant_id, status, filename,
                    total_rows, processed_rows,
                    inserted_count, updated_count, error_count,
                    error_log, failure_reason,
                    created_at, started_at, completed_at
                FROM device_upload_jobs
                WHERE job_id = %s AND tenant_id = %s
                LIMIT 1
                """,
                (job_id, tenant_id),
            )
            row = cur.fetchone()
    if row:
        # Serialise UUID to str for clean JSON output
        row["job_id"] = str(row["job_id"])
    return row
