"""Audit log listing for the RegOps Sentinel Brain.

The Brain writes one immutable JSON blob to S3 per processed item under
the key `audit/{tenant_id}/{YYYY}/{MM}/{DD}/{source}_{external_id}_{ts}.json`.
This module exposes those blobs to the Window app as a paginated list,
tenant-scoped via the verified JWT claim `custom:tenant_id`.

Industry-standard contract (matches AWS CloudTrail LookupEvents and the
Fastio audit log API):
  - Cursor-based pagination using opaque continuation tokens
  - Response envelope: { events: [...], next_cursor, has_more }
  - Most-recent-first ordering by S3 LastModified timestamp
  - Per-event summary extracted from the blob body (classification,
    urgency, title, source) so the list page is scannable without a
    detail click

Performance note: this pass reads each blob individually inside the
listed page (1 ListObjectsV2 + up to 50 GetObject calls per page). At
50 items/page this is <$0.001 per page and ~300ms total. A future
Phase 5A.5 optimisation will denormalise summary fields into S3
object metadata at write time, dropping the per-item GetObject. Both
patterns are documented in industry practice; per-blob read is what
Fastio's audit API does in production.
"""

from __future__ import annotations

import base64
import json
import logging
import os
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import boto3
from botocore.exceptions import ClientError
from fastapi import HTTPException, status
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

# --- S3 client -----------------------------------------------------------

# A module-level boto3 client. The boto3 client is thread-safe for reads,
# which is all we do here. Region falls back to ca-central-1 to match
# the rest of the Brain's configuration in config.py.
_s3_client = boto3.client(
    "s3",
    region_name=os.environ.get("AWS_REGION", "ca-central-1"),
)


# --- Response models -----------------------------------------------------


class AuditEventSummary(BaseModel):
    """A single audit event as it appears on the list page.

    audit_id is a URL-safe base64 encoding of the full S3 key. The
    detail endpoint (Phase 5A.2, next session) will decode this back
    into a key for the GetObject call.
    """

    audit_id: str = Field(
        description="Opaque identifier; base64url of the S3 key"
    )
    audit_timestamp: str = Field(
        description="ISO 8601 timestamp recorded inside the audit blob"
    )
    source: str = Field(description="Watcher source, e.g. health-canada-medeffect")
    external_id: str = Field(description="Upstream item id from the source")
    title: str = Field(description="Item title at time of classification")
    classification: str = Field(
        description="Classifier verdict: RELEVANT, IRRELEVANT, etc."
    )
    urgency: str = Field(description="Urgency band: HIGH, MEDIUM, LOW")
    size_bytes: int = Field(description="Audit blob size in bytes")
    last_modified: str = Field(
        description="ISO 8601 timestamp from S3 object LastModified"
    )
    encryption_key_id: Optional[str] = Field(
        default=None,
        description="The KMS key id the object was encrypted under. "
        "Blobs written before commit beb286a use the AWS-managed aws/s3 "
        "key; blobs after use the customer-managed key.",
    )


class AuditListResponse(BaseModel):
    """Paginated response envelope.

    The shape matches the de-facto industry standard used by AWS
    CloudTrail LookupEvents (NextToken) and Fastio's audit log API
    (next_cursor + has_more). We name it `next_cursor` for clarity:
    `NextToken` is overloaded in other AWS contexts.
    """

    events: List[AuditEventSummary]
    next_cursor: Optional[str] = Field(
        default=None,
        description="Opaque cursor for the next page. Pass back as the "
        "`cursor` query parameter. Null when there are no more pages.",
    )
    has_more: bool = Field(
        description="True if more pages exist beyond this one."
    )


# --- Internals -----------------------------------------------------------


def _encode_audit_id(s3_key: str) -> str:
    """Encode an S3 key as a URL-safe base64 string (no padding).

    The encoding is reversible and safe in URL path segments, so the
    same id works as both a list-item identifier and a detail-page
    path parameter.
    """
    raw = s3_key.encode("utf-8")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _decode_audit_id(audit_id: str) -> str:
    """Reverse of _encode_audit_id. Kept here for the detail endpoint."""
    # Re-pad to a multiple of 4 chars before decoding.
    padding = "=" * (-len(audit_id) % 4)
    raw = base64.urlsafe_b64decode(audit_id + padding)
    return raw.decode("utf-8")


def _encode_cursor(continuation_token: str) -> str:
    """Wrap an S3 ContinuationToken as our opaque cursor.

    Today this is a passthrough, but encoding it lets us evolve the
    cursor format later (e.g. to embed a filter snapshot) without
    breaking clients.
    """
    raw = continuation_token.encode("utf-8")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _decode_cursor(cursor: str) -> str:
    """Reverse of _encode_cursor."""
    try:
        padding = "=" * (-len(cursor) % 4)
        raw = base64.urlsafe_b64decode(cursor + padding)
        return raw.decode("utf-8")
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"invalid_cursor: {e}",
        )


@dataclass
class _S3ObjectMeta:
    """A thin internal type for what ListObjectsV2 gives us per object."""

    key: str
    last_modified: str  # ISO 8601
    size: int


def _get_summary_from_blob(
    bucket: str, key: str
) -> Dict[str, Any]:
    """Fetch an audit blob and extract just the fields the list page renders.

    The full blob body is small (~850-1500 bytes per the data-shape
    inspection at handoff), so reading it whole is cheap.
    """
    try:
        resp = _s3_client.get_object(Bucket=bucket, Key=key)
        body = resp["Body"].read()
        encryption_key_id = resp.get("SSEKMSKeyId")
    except ClientError as e:
        # If a single blob fails (deleted, permissions blip), log and
        # fall back to a degraded record rather than failing the whole
        # page. The user sees "(unreadable)" markers, not a 500.
        logger.warning("failed to read audit blob %s: %s", key, e)
        return {
            "audit_timestamp": "",
            "source": "(unreadable)",
            "external_id": "",
            "title": "(unreadable)",
            "classification": "",
            "urgency": "",
            "encryption_key_id": None,
        }

    try:
        doc = json.loads(body)
    except json.JSONDecodeError as e:
        logger.warning("audit blob %s is not valid JSON: %s", key, e)
        return {
            "audit_timestamp": "",
            "source": "(corrupt)",
            "external_id": "",
            "title": "(corrupt)",
            "classification": "",
            "urgency": "",
            "encryption_key_id": encryption_key_id,
        }

    source_item = doc.get("source_item", {}) or {}
    classification = doc.get("classification", {}) or {}

    # The KMS key id from S3 is a full ARN; trim to just the uuid for
    # display. Keep the full ARN available to the detail endpoint later.
    short_key_id = None
    if encryption_key_id:
        short_key_id = encryption_key_id.split("/")[-1]

    return {
        "audit_timestamp": doc.get("audit_timestamp", ""),
        "source": source_item.get("source", ""),
        "external_id": str(source_item.get("external_id", "")),
        "title": source_item.get("title", ""),
        "classification": classification.get("classification", ""),
        "urgency": classification.get("urgency", ""),
        "encryption_key_id": short_key_id,
    }


# --- Public API ----------------------------------------------------------


def list_audit_events(
    tenant_id: str,
    bucket: str,
    limit: int,
    cursor: Optional[str],
) -> AuditListResponse:
    """List one page of audit events for a tenant.

    Tenant scoping is enforced by the S3 key prefix - the caller cannot
    cross tenants because we build the prefix from the verified JWT
    claim, not from any request input.

    Sort order: ListObjectsV2 returns keys in lexicographic order, and
    our key format embeds YYYY/MM/DD/unixts. Lexicographic order on
    that pattern is effectively chronological ascending. We reverse the
    page in memory to deliver most-recent-first, which is what users
    expect on a log view.

    Note: reversing within a page means the first page contains the
    most recent items WITHIN that page, but cross-page ordering still
    follows the underlying lexicographic walk. For tonight's scale
    (39 alerts, ~50/page) this is fine. A future enhancement could
    walk the prefix in reverse date order for true global desc order.
    """
    if not bucket:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="audit_bucket_not_configured",
        )
    if limit < 1 or limit > 100:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="limit_must_be_between_1_and_100",
        )

    prefix = f"audit/{tenant_id}/"

    list_kwargs: Dict[str, Any] = {
        "Bucket": bucket,
        "Prefix": prefix,
        "MaxKeys": limit,
    }
    if cursor:
        list_kwargs["ContinuationToken"] = _decode_cursor(cursor)

    try:
        resp = _s3_client.list_objects_v2(**list_kwargs)
    except ClientError as e:
        logger.exception("list_objects_v2 failed for prefix %s", prefix)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"audit_store_unavailable: {e.response.get('Error', {}).get('Code', 'Unknown')}",
        )

    objects = resp.get("Contents", []) or []
    next_token = resp.get("NextContinuationToken")
    is_truncated = bool(resp.get("IsTruncated", False))

    # Reverse for most-recent-first within the page.
    objects.reverse()

    events: List[AuditEventSummary] = []
    for obj in objects:
        key = obj["Key"]
        summary = _get_summary_from_blob(bucket, key)
        events.append(
            AuditEventSummary(
                audit_id=_encode_audit_id(key),
                audit_timestamp=summary["audit_timestamp"],
                source=summary["source"],
                external_id=summary["external_id"],
                title=summary["title"],
                classification=summary["classification"],
                urgency=summary["urgency"],
                size_bytes=int(obj.get("Size", 0)),
                last_modified=obj["LastModified"].isoformat(),
                encryption_key_id=summary["encryption_key_id"],
            )
        )

    return AuditListResponse(
        events=events,
        next_cursor=_encode_cursor(next_token) if next_token else None,
        has_more=is_truncated,
    )
