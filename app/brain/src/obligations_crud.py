"""Obligations CRUD module (Phase 5C.2).

Pure DB operations for creating, updating, completing, and deleting
obligations. All functions are tenant-scoped from the JWT - none of them
take a tenant_id from request input.

The audit-blob writes happen at the endpoint layer (main.py) AFTER the
DB write succeeds. This keeps the audit module concerns out of the SQL
module and means if a regulator wants to know "did this DB row ever
exist" the answer is in S3, not coupled to whether a Python try/except
chose to write or not.
"""

from __future__ import annotations

import logging
from typing import Any

from psycopg.rows import dict_row

from .db import get_connection

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------
# Enum validation - server-side hard validation (mirrors UI hints)
# ---------------------------------------------------------------------

VALID_OBLIGATION_TYPES = {
    "mdl_renewal",
    "adverse_event_report",
    "recall_notification",
    "qms_audit",
    "post_market_surveillance",
    "udi_submission",
    "incident_investigation",
}

VALID_FREQUENCIES = {
    "one_time",
    "annual",
    "quarterly",
    "monthly",
    "as_required",
}

VALID_STATUSES = {
    "upcoming",
    "due_soon",
    "overdue",
    "in_progress",
    "completed",
    "not_applicable",
}

VALID_SEVERITIES = {"critical", "high", "medium", "low"}

VALID_REGULATORY_BODIES = {
    "health_canada",
    "fda",
    "iso_auditor",
    "internal_qms",
}

# Columns the caller is allowed to set on CREATE or PATCH. tenant_id,
# obligation_id, created_at, updated_at, completed_at, and the joined
# device_brand_name / device_di are server-managed and never accepted
# from input.
_WRITEABLE_COLUMNS = {
    "device_id",
    "title",
    "description",
    "obligation_type",
    "frequency",
    "status",
    "regulatory_body",
    "due_at",
    "severity_if_missed",
    "responsible_party",
    "related_alert_id",
    "notes",
}


class ValidationError(ValueError):
    """Raised when input fails validation. Caller converts to HTTP 400."""


# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------


def _validate_for_create(payload: dict[str, Any]) -> dict[str, Any]:
    """Validate a CREATE payload. Returns the cleaned, accepted subset.

    Raises ValidationError on any rule violation. We're strict here -
    unknown fields are dropped silently (forgive), but invalid enum
    values are rejected (be strict on what we accept). Same Postel
    rule the rest of the brain follows.
    """
    cleaned = _drop_unknown_fields(payload)

    # Required fields. Frequency and severity_if_missed default downstream
    # but title and obligation_type don't - we need them to write a
    # meaningful row.
    if not cleaned.get("title"):
        raise ValidationError("title is required")
    if len(cleaned["title"]) > 200:
        raise ValidationError("title cannot exceed 200 characters")
    if not cleaned.get("obligation_type"):
        raise ValidationError("obligation_type is required")
    if cleaned["obligation_type"] not in VALID_OBLIGATION_TYPES:
        raise ValidationError(
            f"obligation_type must be one of {sorted(VALID_OBLIGATION_TYPES)}"
        )

    # frequency defaults to as_required for the safest behaviour.
    cleaned.setdefault("frequency", "as_required")
    if cleaned["frequency"] not in VALID_FREQUENCIES:
        raise ValidationError(
            f"frequency must be one of {sorted(VALID_FREQUENCIES)}"
        )

    # severity_if_missed defaults to medium.
    cleaned.setdefault("severity_if_missed", "medium")
    if cleaned["severity_if_missed"] not in VALID_SEVERITIES:
        raise ValidationError(
            f"severity_if_missed must be one of {sorted(VALID_SEVERITIES)}"
        )

    # Status defaults to upcoming on create. A caller setting status=
    # completed at creation time would need a real reason; we allow it
    # but the audit blob will record it.
    cleaned.setdefault("status", "upcoming")
    if cleaned["status"] not in VALID_STATUSES:
        raise ValidationError(
            f"status must be one of {sorted(VALID_STATUSES)}"
        )

    # regulatory_body is optional but if provided must be valid.
    rb = cleaned.get("regulatory_body")
    if rb is not None and rb != "" and rb not in VALID_REGULATORY_BODIES:
        raise ValidationError(
            f"regulatory_body must be one of {sorted(VALID_REGULATORY_BODIES)}"
        )
    if rb == "":
        cleaned["regulatory_body"] = None

    # Field interdependency rules (industry standard - "smart form"):
    # - For frequency != as_required, due_at is required. A recurring
    #   obligation needs a next-due date to be useful.
    if cleaned["frequency"] != "as_required" and not cleaned.get("due_at"):
        raise ValidationError(
            "due_at is required when frequency is not 'as_required'"
        )

    # - mdl_renewal and udi_submission target a specific device. Without
    #   a device_id the obligation is ambiguous ("renew the MDL for what?").
    if cleaned["obligation_type"] in {"mdl_renewal", "udi_submission"}:
        if not cleaned.get("device_id"):
            raise ValidationError(
                f"device_id is required for obligation_type "
                f"{cleaned['obligation_type']!r}"
            )

    return cleaned


def _validate_for_update(payload: dict[str, Any]) -> dict[str, Any]:
    """Validate a PATCH payload. Returns the cleaned subset.

    PATCH semantics: only fields present in the payload are updated. We
    still validate any enum values that ARE present, but we don't enforce
    required-field rules that CREATE enforces (the row already exists).
    """
    cleaned = _drop_unknown_fields(payload)
    if not cleaned:
        raise ValidationError("at least one field must be provided")

    if "title" in cleaned:
        if not cleaned["title"]:
            raise ValidationError("title cannot be empty")
        if len(cleaned["title"]) > 200:
            raise ValidationError("title cannot exceed 200 characters")

    if "obligation_type" in cleaned and (
        cleaned["obligation_type"] not in VALID_OBLIGATION_TYPES
    ):
        raise ValidationError(
            f"obligation_type must be one of {sorted(VALID_OBLIGATION_TYPES)}"
        )

    if "frequency" in cleaned and cleaned["frequency"] not in VALID_FREQUENCIES:
        raise ValidationError(
            f"frequency must be one of {sorted(VALID_FREQUENCIES)}"
        )

    if (
        "severity_if_missed" in cleaned
        and cleaned["severity_if_missed"] not in VALID_SEVERITIES
    ):
        raise ValidationError(
            f"severity_if_missed must be one of {sorted(VALID_SEVERITIES)}"
        )

    if "status" in cleaned and cleaned["status"] not in VALID_STATUSES:
        raise ValidationError(
            f"status must be one of {sorted(VALID_STATUSES)}"
        )

    if "regulatory_body" in cleaned:
        rb = cleaned["regulatory_body"]
        if rb is not None and rb != "" and rb not in VALID_REGULATORY_BODIES:
            raise ValidationError(
                f"regulatory_body must be one of "
                f"{sorted(VALID_REGULATORY_BODIES)}"
            )
        if rb == "":
            cleaned["regulatory_body"] = None

    return cleaned


def _drop_unknown_fields(payload: dict[str, Any]) -> dict[str, Any]:
    """Return a copy with only the writeable columns kept."""
    return {k: v for k, v in payload.items() if k in _WRITEABLE_COLUMNS}


# ---------------------------------------------------------------------
# DB operations
# ---------------------------------------------------------------------


def get_obligation(tenant_id: str, obligation_id: int) -> dict | None:
    """Fetch one obligation with joined device columns. Tenant-scoped.

    Returns None for cross-tenant or missing-id lookups so the endpoint
    can return 404. Used by PATCH/COMPLETE/DELETE to capture the 'before'
    state for the audit blob.
    """
    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT
                    o.*,
                    d.brand_name AS device_brand_name,
                    d.di AS device_di
                FROM obligations o
                LEFT JOIN devices d ON d.device_id = o.device_id
                WHERE o.obligation_id = %s AND o.tenant_id = %s
                LIMIT 1
                """,
                (obligation_id, tenant_id),
            )
            return cur.fetchone()


def create_obligation(tenant_id: str, payload: dict[str, Any]) -> dict:
    """Insert a new obligation. Returns the inserted row with joins.

    Caller passes the JSON body from the POST; we validate, insert, and
    re-fetch via get_obligation so the returned shape matches the GET
    detail endpoint exactly.
    """
    cleaned = _validate_for_create(payload)

    with get_connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                INSERT INTO obligations (
                    tenant_id, device_id, title, description,
                    obligation_type, frequency, status, regulatory_body,
                    due_at, severity_if_missed, responsible_party,
                    related_alert_id, notes
                ) VALUES (
                    %(tenant_id)s, %(device_id)s, %(title)s, %(description)s,
                    %(obligation_type)s, %(frequency)s, %(status)s,
                    %(regulatory_body)s, %(due_at)s, %(severity_if_missed)s,
                    %(responsible_party)s, %(related_alert_id)s, %(notes)s
                )
                RETURNING obligation_id
                """,
                {
                    "tenant_id": tenant_id,
                    "device_id": cleaned.get("device_id"),
                    "title": cleaned["title"],
                    "description": cleaned.get("description"),
                    "obligation_type": cleaned["obligation_type"],
                    "frequency": cleaned["frequency"],
                    "status": cleaned["status"],
                    "regulatory_body": cleaned.get("regulatory_body"),
                    "due_at": cleaned.get("due_at"),
                    "severity_if_missed": cleaned["severity_if_missed"],
                    "responsible_party": cleaned.get("responsible_party"),
                    "related_alert_id": cleaned.get("related_alert_id"),
                    "notes": cleaned.get("notes"),
                },
            )
            new_id = cur.fetchone()["obligation_id"]
            conn.commit()

    inserted = get_obligation(tenant_id, new_id)
    if inserted is None:
        # Shouldn't happen - we just inserted and committed. If it did,
        # something else (deletion in another request) raced us.
        raise RuntimeError(
            f"obligation {new_id} not found immediately after insert"
        )
    return inserted


def update_obligation(
    tenant_id: str,
    obligation_id: int,
    payload: dict[str, Any],
) -> tuple[dict | None, dict | None]:
    """PATCH an obligation. Returns (before, after) tuple.

    Returns (None, None) if the obligation doesn't exist for this tenant
    (caller maps to 404). Returns (before, after) on success so the
    audit blob can record both states.

    Status changes to/from 'completed' are handled here (PATCH can set
    status=completed too), but the dedicated complete_obligation()
    endpoint is the preferred path because it auto-sets completed_at.
    """
    cleaned = _validate_for_update(payload)

    before = get_obligation(tenant_id, obligation_id)
    if before is None:
        return None, None

    # Build a dynamic UPDATE - only the fields the caller actually sent.
    # Done with named placeholders so the SQL is safe regardless of
    # input keys.
    set_clauses = []
    params: dict[str, Any] = {
        "obligation_id": obligation_id,
        "tenant_id": tenant_id,
    }
    for col, val in cleaned.items():
        set_clauses.append(f"{col} = %({col})s")
        params[col] = val

    # If status is being set to 'completed' and the row isn't already
    # completed, set completed_at too. The dedicated complete endpoint
    # does this more cleanly, but PATCH accepting status=completed has
    # to handle the same case for consistency.
    if (
        cleaned.get("status") == "completed"
        and before.get("status") != "completed"
    ):
        set_clauses.append("completed_at = NOW()")

    # updated_at is auto-updated by the search_vector trigger when title/
    # description/etc change, but we set it explicitly here so it
    # advances even when only e.g. notes changes.
    set_clauses.append("updated_at = NOW()")

    sql = f"""
        UPDATE obligations
        SET {', '.join(set_clauses)}
        WHERE obligation_id = %(obligation_id)s
          AND tenant_id = %(tenant_id)s
    """

    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            conn.commit()

    after = get_obligation(tenant_id, obligation_id)
    return before, after


def complete_obligation(
    tenant_id: str,
    obligation_id: int,
) -> tuple[dict | None, dict | None]:
    """Mark an obligation complete. Sets status=completed, completed_at=NOW().

    Idempotent: calling complete() on an already-completed row is a no-op
    that returns the same row twice. The audit log will still record the
    call (a duplicate complete is itself an event a regulator might
    want to see).
    """
    before = get_obligation(tenant_id, obligation_id)
    if before is None:
        return None, None

    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE obligations
                SET status = 'completed',
                    completed_at = COALESCE(completed_at, NOW()),
                    updated_at = NOW()
                WHERE obligation_id = %s AND tenant_id = %s
                """,
                (obligation_id, tenant_id),
            )
            conn.commit()

    after = get_obligation(tenant_id, obligation_id)
    return before, after


def delete_obligation(
    tenant_id: str,
    obligation_id: int,
) -> dict | None:
    """Hard-delete an obligation. Returns the deleted row, or None if missing.

    Hard delete is paired with an immutable S3 audit blob written by the
    endpoint layer. The operational DB loses the row, but a regulator
    auditing the system sees the deletion event in S3 with Object Lock
    retention - same audit posture as the classification trail.

    Caller is responsible for writing the audit blob AFTER this returns;
    we can't do it here because we need the actor email from the JWT,
    which lives at the endpoint layer.
    """
    before = get_obligation(tenant_id, obligation_id)
    if before is None:
        return None

    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                DELETE FROM obligations
                WHERE obligation_id = %s AND tenant_id = %s
                """,
                (obligation_id, tenant_id),
            )
            conn.commit()

    return before
