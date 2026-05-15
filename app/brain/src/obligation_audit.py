"""Audit blob writer for obligation CRUD events (Phase 5C.2).

Every state-changing action on the obligations table writes an immutable
audit blob to the same S3 audit bucket the SQS worker uses. Bucket has
Object Lock GOVERNANCE mode + KMS encryption + versioning; once written,
the blob cannot be modified or deleted within its retention window even
by the bucket owner.

This is parallel to worker.write_audit_blob() but the payload schema is
CRUD-shaped (action + actor + before/after snapshots) instead of
classification-shaped (source_item + classification). Keeping them in
separate modules so each can evolve without breaking the other.

Why audit the create / update / complete / delete path at all:
A regulatory platform that lets users add and remove obligations needs
to prove the database state has provenance. A regulator auditing the
system later sees the current obligations table - they cannot see what
obligations once existed but were deleted, or what fields changed when
between yesterday and today. The audit blobs are the answer to both
questions: append-only, tenant-scoped, KMS-encrypted, Object-Lock
protected.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from .config import AUDIT_KMS_KEY_ARN, S3_AUDIT_BUCKET

logger = logging.getLogger(__name__)

# Module-level S3 client. Same pattern as worker.py - one client per
# process, reused across requests. boto3 clients are thread-safe.
_s3 = boto3.client(
    "s3",
    region_name=os.environ.get("AWS_REGION", "ca-central-1"),
)


# Vocabulary for the 'action' field. Kept here as a closed enum so the
# audit-log search/filter UI eventually has a known set of values to
# work with.
ACTION_CREATE = "obligation_create"
ACTION_UPDATE = "obligation_update"
ACTION_COMPLETE = "obligation_complete"
ACTION_DELETE = "obligation_delete"

_VALID_ACTIONS = {
    ACTION_CREATE,
    ACTION_UPDATE,
    ACTION_COMPLETE,
    ACTION_DELETE,
}


def write_obligation_audit_blob(
    action: str,
    tenant_id: str,
    obligation_id: int | None,
    actor_email: str,
    actor_user_id: str | None,
    before: dict[str, Any] | None,
    after: dict[str, Any] | None,
) -> str:
    """Write a single audit blob for an obligation CRUD event.

    Returns the S3 key. Raises ClientError if the put_object call fails;
    the caller decides whether to surface that to the user (right now we
    do, because a regulator-grade audit log that silently drops writes
    is worse than failing the user request).

    Args:
        action: One of ACTION_CREATE / UPDATE / COMPLETE / DELETE.
        tenant_id: From the verified ID token's custom:tenant_id claim.
            Used as the S3 prefix so the same boundary the application
            enforces is also a storage-layer boundary.
        obligation_id: The id being acted upon. Optional only because
            CREATE happens before we know the new id - callers using
            CREATE may pass None and re-issue with the id after insert,
            OR (simpler) pass the id post-insert.
        actor_email: Who did this. Pulled from the JWT, never trusted
            from request input.
        actor_user_id: Cognito 'sub' claim if available. Optional.
        before: Row state before the change. None for CREATE.
        after: Row state after the change. None for DELETE.
    """
    if action not in _VALID_ACTIONS:
        raise ValueError(
            f"Unknown audit action {action!r}; "
            f"must be one of {sorted(_VALID_ACTIONS)}"
        )

    if not S3_AUDIT_BUCKET:
        # In a dev environment without the bucket configured, fail loud
        # rather than silently dropping the audit record. The whole point
        # of the audit trail is that it's not silently skippable.
        raise RuntimeError(
            "S3_AUDIT_BUCKET is not configured; "
            "obligation audit cannot be written"
        )

    timestamp = datetime.now(timezone.utc)

    # Mirror worker.py's key naming convention so all audit blobs - alert
    # classifications and obligation events - share the same hierarchy.
    # Compliance leads exploring the bucket will see one consistent layout
    # per tenant.
    obligation_id_str = (
        str(obligation_id) if obligation_id is not None else "new"
    )
    key = (
        f"audit/{tenant_id}/"
        f"{timestamp.strftime('%Y/%m/%d')}/"
        f"{action}_{obligation_id_str}_{int(timestamp.timestamp())}.json"
    )

    payload: dict[str, Any] = {
        "tenant_id": tenant_id,
        "audit_timestamp": timestamp.isoformat(),
        "event_kind": "obligation",
        "action": action,
        "obligation_id": obligation_id,
        "actor": {
            "email": actor_email,
            "user_id": actor_user_id,
        },
        "before": _serialise_for_json(before),
        "after": _serialise_for_json(after),
    }

    try:
        _s3.put_object(
            Bucket=S3_AUDIT_BUCKET,
            Key=key,
            Body=json.dumps(payload, default=str).encode("utf-8"),
            ContentType="application/json",
            ServerSideEncryption="aws:kms",
            SSEKMSKeyId=AUDIT_KMS_KEY_ARN,
        )
    except ClientError:
        logger.exception(
            "obligation audit write failed: action=%s tenant=%s obligation=%s",
            action,
            tenant_id,
            obligation_id,
        )
        raise

    logger.info(
        "obligation_audit_written action=%s tenant=%s obligation=%s key=%s",
        action,
        tenant_id,
        obligation_id,
        key,
    )
    return key


def _serialise_for_json(row: dict[str, Any] | None) -> dict[str, Any] | None:
    """Convert a DB row (with datetimes etc.) into JSON-serialisable form.

    psycopg's dict_row returns datetime objects for timestamp columns,
    Decimal for numeric columns, and so on. json.dumps with default=str
    handles most of these, but being explicit here means the audit blob
    has consistent ISO 8601 timestamps regardless of how the row was
    fetched.
    """
    if row is None:
        return None
    out: dict[str, Any] = {}
    for k, v in row.items():
        if isinstance(v, datetime):
            out[k] = v.isoformat()
        else:
            out[k] = v
    return out
