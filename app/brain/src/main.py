"""FastAPI app exposing health checks, classification, and alerts.
The SQS worker runs in a background thread."""
import logging
import os
import threading
from contextlib import asynccontextmanager
from fastapi import Depends, FastAPI, HTTPException, Request
from psycopg.rows import dict_row
from pydantic import BaseModel
from .auth import CurrentUser, current_user
from .audit import AuditListResponse, list_audit_events
from .device_upload import create_upload_job, get_upload_job
from .config import LOG_LEVEL, S3_AUDIT_BUCKET, get_azure_openai_credentials
from .db import init_schema, get_connection
from .worker import poll_loop
from .classifier import classify
from .obligations_crud import (
    create_obligation,
    update_obligation,
    complete_obligation,
    delete_obligation,
    ValidationError,
)
from .obligation_audit import (
    write_obligation_audit_blob,
    ACTION_CREATE,
    ACTION_UPDATE,
    ACTION_COMPLETE,
    ACTION_DELETE,
)

logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger(__name__)


def start_worker_thread():
    thread = threading.Thread(target=poll_loop, daemon=True, name="sqs-worker")
    thread.start()
    logger.info("SQS worker thread started")


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Brain starting up")
    try:
        init_schema()
    except Exception as e:
        logger.error(f"Schema init failed at startup: {e}")
    if os.environ.get("DISABLE_WORKER", "false").lower() != "true":
        start_worker_thread()
    yield
    logger.info("Brain shutting down")


app = FastAPI(title="RegOps Sentinel Brain", version="0.2.0", lifespan=lifespan)


# OpenTelemetry instrumentation (Phase 6B).
#
# Initialised conditionally: only when OTEL_EXPORTER_OTLP_ENDPOINT is
# set in the environment (the ECS task sets this to the ADOT collector
# sidecar at http://127.0.0.1:4318). Local dev runs without the env var
# set and skips OTel entirely so devs do not need a running collector
# to develop against the brain.
#
# Wrapped in try/except: if OTel initialization fails for any reason
# (transitive dep conflict, broken instrumentation in a release), the
# brain still starts and serves traffic - we just lose tracing. Tracing
# is observability, not a hard dependency.
#
# /health and /health/db excluded from FastAPI auto-instrumentation:
# these fire every 30s from ECS container health checks, which would
# flood the trace store with no diagnostic value. Real user requests
# are still traced.
#
# The opentelemetry-distro package auto-configures the tracer provider
# and the OTLP exporter from environment variables, so we do not need
# to manually wire those - just call the instrumentors.
def _instrument_otel(app: FastAPI) -> None:
    if not os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT"):
        logger.info("OTEL_EXPORTER_OTLP_ENDPOINT not set; skipping OpenTelemetry init")
        return
    try:
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
        from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
        from opentelemetry.instrumentation.psycopg import PsycopgInstrumentor
        from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

        FastAPIInstrumentor.instrument_app(app, excluded_urls="/health,/health/db")
        BotocoreInstrumentor().instrument()
        PsycopgInstrumentor().instrument()
        HTTPXClientInstrumentor().instrument()

        logger.info("OpenTelemetry instrumentation initialized")
    except Exception as e:
        logger.error(f"OpenTelemetry init failed; continuing without tracing: {e}")


_instrument_otel(app)


# CORS note: we do NOT add CORSMiddleware here. The Window app calls this
# service through its server-side BFF route handlers (Next.js -> Brain over
# the AWS network), not directly from the browser, so browsers never see
# cross-origin requests to the Brain. Adding CORS would only widen the
# attack surface.


class ClassifyRequest(BaseModel):
    source: str
    external_id: str
    title: str
    summary: str = ""
    url: str = ""
    status: str = ""
    type: str = ""


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/health/db")
def health_db():
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1 AS ok")
                result = cur.fetchone()
        return {"status": "ok", "db": result}
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"db_unavailable: {e}")


@app.post("/classify")
def classify_endpoint(req: ClassifyRequest):
    try:
        deployment_name = get_azure_openai_credentials().get(
            "deployment_name", "gpt-4o-regops"
        )
        result = classify(req.model_dump(), deployment_name)
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/alerts")
def list_alerts(
    user: CurrentUser = Depends(current_user),
    limit: int = 50,
):
    """List alerts for the caller's tenant.

    tenant_id comes from the verified ID token's custom:tenant_id claim.
    A user holding a token for tenant A cannot see tenant B's alerts even
    by passing a different tenant_id - there is no such query parameter.
    """
    try:
        # dict_row returns each row as a dict keyed by column name, so the
        # JSON response uses real field names instead of position-ordered
        # tuples. Easier for the BFF to consume and self-documenting.
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT alert_id, tenant_id, source, external_id, title,
                           classification, urgency, relevance_score,
                           product_categories, classified_at
                    FROM alerts
                    WHERE tenant_id = %s
                    ORDER BY classified_at DESC
                    LIMIT %s
                    """,
                    (user.tenant_id, limit),
                )
                rows = cur.fetchall()
        return {
            "tenant_id": user.tenant_id,
            "count": len(rows),
            "alerts": rows,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("list_alerts failed for tenant %s", user.tenant_id)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/alerts/{alert_id}")
def get_alert(
    alert_id: str,
    user: CurrentUser = Depends(current_user),
):
    """Fetch a single alert by id, scoped to the caller's tenant.

    A cross-tenant lookup (user from tenant A asking for tenant B's alert)
    returns 404, not 403 - we do not even confirm the alert exists for
    another tenant. This is the standard 'unguessable response' pattern.
    """
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT *
                    FROM alerts
                    WHERE alert_id = %s AND tenant_id = %s
                    LIMIT 1
                    """,
                    (alert_id, user.tenant_id),
                )
                row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="alert_not_found")
        return row
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "get_alert failed for tenant %s, alert %s",
            user.tenant_id,
            alert_id,
        )
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/audit", response_model=AuditListResponse)
def list_audit(
    user: CurrentUser = Depends(current_user),
    limit: int = 50,
    cursor: str | None = None,
):
    """List audit-log events for the caller's tenant.

    Each event corresponds to one immutable JSON blob written to S3 by
    the worker after a classification. tenant_id comes from the verified
    ID token's custom:tenant_id claim - there is no tenant_id query
    parameter and the S3 prefix is built server-side, so a token holder
    for tenant A cannot read tenant B's audit trail.

    Pagination is cursor-based (opaque token). Pass the next_cursor from
    a previous response as the cursor query parameter to fetch the next
    page. Default page size is 50 (matches AWS CloudTrail LookupEvents);
    max is 100.
    """
    try:
        return list_audit_events(
            tenant_id=user.tenant_id,
            bucket=S3_AUDIT_BUCKET,
            limit=limit,
            cursor=cursor,
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "list_audit failed for tenant %s",
            user.tenant_id,
        )
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/devices")
def list_devices(
    user: CurrentUser = Depends(current_user),
    limit: int = 100,
):
    """List devices in the caller's tenant catalog.

    tenant_id comes from the verified ID token's custom:tenant_id claim.
    A user holding a token for tenant A cannot see tenant B's devices
    even by passing a different tenant_id - there is no such query
    parameter and the WHERE clause is built from the JWT, not request
    input.
    """
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT
                        device_id, tenant_id, di, brand_name, model_number,
                        manufacturer, mdl_number, device_class, status,
                        clearance_type, product_categories, notes,
                        created_at, updated_at
                    FROM devices
                    WHERE tenant_id = %s
                    ORDER BY device_class ASC, brand_name ASC
                    LIMIT %s
                    """,
                    (user.tenant_id, limit),
                )
                rows = cur.fetchall()
        return {
            "tenant_id": user.tenant_id,
            "count": len(rows),
            "devices": rows,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("list_devices failed for tenant %s", user.tenant_id)
        raise HTTPException(status_code=500, detail=str(e))


# ===== Phase 5B.2: Device CSV upload (async) =====

# Hard cap on CSV payload size in bytes. 1MB is ~10,000 device rows in
# MDALL format, an order of magnitude more than any realistic demo
# upload. Anything bigger gets rejected at the HTTP layer before we
# read it into memory.
DEVICE_UPLOAD_MAX_BYTES = 1024 * 1024


@app.post("/devices/upload", status_code=202)
async def post_devices_upload(
    request: Request,
    user: CurrentUser = Depends(current_user),
):
    """Accept a CSV body, create an upload job, return its job_id.

    Returns 202 Accepted because the work happens asynchronously. The
    caller polls GET /devices/upload/{job_id} for progress.
    """
    body = await request.body()
    if len(body) > DEVICE_UPLOAD_MAX_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"upload exceeds max size of {DEVICE_UPLOAD_MAX_BYTES} bytes",
        )
    if not body:
        raise HTTPException(status_code=400, detail="empty payload")

    try:
        payload_csv = body.decode("utf-8")
    except UnicodeDecodeError:
        raise HTTPException(status_code=400, detail="payload must be UTF-8 CSV")

    filename = request.headers.get("x-upload-filename")

    try:
        job_id = create_upload_job(
            tenant_id=user.tenant_id,
            payload_csv=payload_csv,
            filename=filename,
        )
    except Exception:
        logger.exception("failed to create device upload job")
        raise HTTPException(status_code=500, detail="failed to queue upload")

    return {"job_id": job_id, "status": "queued"}


@app.get("/devices/upload/{job_id}")
def get_devices_upload(
    job_id: str,
    user: CurrentUser = Depends(current_user),
):
    """Return current state of an upload job. Tenant-scoped."""
    job = get_upload_job(tenant_id=user.tenant_id, job_id=job_id)
    if not job:
        # Cross-tenant lookups, malformed UUIDs, and not-found all return
        # 404 to avoid leaking job existence to unauthorised callers.
        raise HTTPException(status_code=404, detail="job not found")
    return job




@app.get("/devices/{device_id}")
def get_device(
    device_id: int,
    user: CurrentUser = Depends(current_user),
):
    """Fetch a single device by id, scoped to the caller's tenant.

    A cross-tenant lookup (user from tenant A asking for tenant B's
    device) returns 404, not 403 - we do not even confirm the device
    exists for another tenant. Same 'unguessable response' pattern as
    /alerts/{alert_id}.
    """
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT *
                    FROM devices
                    WHERE device_id = %s AND tenant_id = %s
                    LIMIT 1
                    """,
                    (device_id, user.tenant_id),
                )
                row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="device_not_found")
        return row
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "get_device failed for tenant %s, device %s",
            user.tenant_id,
            device_id,
        )
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================
# Phase 5C.2: Obligations CRUD endpoints
#
# These are registered BEFORE the existing @app.get("/obligations/{id}")
# below to avoid the route specificity bug we hit in Phase 5B.2
# (/devices/{id} capturing /devices/upload as id="upload").
#
# Every state-changing endpoint writes an immutable S3 audit blob AFTER
# the DB write succeeds. Audit write failures surface to the caller as
# 500s because a silently-skipped audit defeats the purpose of an
# audit trail.
# ============================================================

@app.post("/obligations", status_code=201)
def create_obligation_endpoint(
    request: Request,
    payload: dict,
    user: CurrentUser = Depends(current_user),
):
    """Create a new obligation. Returns the inserted row.

    Audited as ACTION_CREATE with before=None.
    """
    try:
        created = create_obligation(user.tenant_id, payload)
    except ValidationError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "create_obligation failed for tenant %s", user.tenant_id
        )
        raise HTTPException(status_code=500, detail=str(e))

    try:
        write_obligation_audit_blob(
            action=ACTION_CREATE,
            tenant_id=user.tenant_id,
            obligation_id=created["obligation_id"],
            actor_email=user.email,
            actor_user_id=user.sub,
            before=None,
            after=created,
        )
    except Exception:
        # Audit write failed AFTER the DB insert succeeded. The row exists
        # but has no audit trail. We surface a 500 so the operator knows
        # to investigate (and ideally manually delete the row + re-create
        # cleanly), rather than pretending all is well.
        logger.exception(
            "audit write failed for tenant %s obligation %s; "
            "DB write succeeded but audit is missing",
            user.tenant_id,
            created["obligation_id"],
        )
        raise HTTPException(
            status_code=500,
            detail="obligation_created_but_audit_failed",
        )

    return created


@app.patch("/obligations/{obligation_id}")
def update_obligation_endpoint(
    obligation_id: int,
    payload: dict,
    user: CurrentUser = Depends(current_user),
):
    """Partially update an obligation. Returns the updated row.

    Audited as ACTION_UPDATE with before+after snapshots so the audit
    trail captures the exact diff a regulator would ask about.
    """
    try:
        before, after = update_obligation(user.tenant_id, obligation_id, payload)
    except ValidationError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "update_obligation failed for tenant %s obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(status_code=500, detail=str(e))

    if before is None:
        raise HTTPException(status_code=404, detail="obligation_not_found")

    try:
        write_obligation_audit_blob(
            action=ACTION_UPDATE,
            tenant_id=user.tenant_id,
            obligation_id=obligation_id,
            actor_email=user.email,
            actor_user_id=user.sub,
            before=before,
            after=after,
        )
    except Exception:
        logger.exception(
            "audit write failed for tenant %s obligation %s update",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(
            status_code=500,
            detail="obligation_updated_but_audit_failed",
        )

    return after


@app.post("/obligations/{obligation_id}/complete")
def complete_obligation_endpoint(
    obligation_id: int,
    user: CurrentUser = Depends(current_user),
):
    """Mark an obligation complete. Sets status=completed, completed_at=NOW().

    Idempotent: calling complete() twice is OK. The audit log records each
    call separately so a regulator can see all "complete this" events.
    """
    try:
        before, after = complete_obligation(user.tenant_id, obligation_id)
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "complete_obligation failed for tenant %s obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(status_code=500, detail=str(e))

    if before is None:
        raise HTTPException(status_code=404, detail="obligation_not_found")

    try:
        write_obligation_audit_blob(
            action=ACTION_COMPLETE,
            tenant_id=user.tenant_id,
            obligation_id=obligation_id,
            actor_email=user.email,
            actor_user_id=user.sub,
            before=before,
            after=after,
        )
    except Exception:
        logger.exception(
            "audit write failed for tenant %s obligation %s complete",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(
            status_code=500,
            detail="obligation_completed_but_audit_failed",
        )

    return after


@app.delete("/obligations/{obligation_id}", status_code=200)
def delete_obligation_endpoint(
    obligation_id: int,
    user: CurrentUser = Depends(current_user),
):
    """Hard-delete an obligation. The audit blob remains in S3 forever.

    Returns the deleted row's snapshot so the UI can render a confirmation
    message ("deleted MDL renewal for Aquilion CT scanner") rather than
    a generic "deleted" string.
    """
    # CRITICAL ORDER: write the audit blob FIRST, then do the DB delete.
    # If the order were reversed and the audit write failed, we'd have a
    # row that no longer exists with no audit trail of its deletion.
    # Writing audit-then-delete means the worst case is a stale audit
    # blob for a row that wasn't actually deleted (preferable: a
    # regulator sees "we tried to delete this" instead of "this just
    # disappeared with no record").
    try:
        from .obligations_crud import get_obligation
        snapshot = get_obligation(user.tenant_id, obligation_id)
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "pre-delete fetch failed for tenant %s obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(status_code=500, detail=str(e))

    if snapshot is None:
        raise HTTPException(status_code=404, detail="obligation_not_found")

    try:
        write_obligation_audit_blob(
            action=ACTION_DELETE,
            tenant_id=user.tenant_id,
            obligation_id=obligation_id,
            actor_email=user.email,
            actor_user_id=user.sub,
            before=snapshot,
            after=None,
        )
    except Exception:
        logger.exception(
            "audit write failed for tenant %s obligation %s delete; "
            "delete was NOT performed",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(
            status_code=500,
            detail="audit_write_failed_delete_aborted",
        )

    # Audit is durable; now do the DB delete.
    try:
        deleted = delete_obligation(user.tenant_id, obligation_id)
    except HTTPException:
        raise
    except Exception as e:
        # The audit blob says we deleted but the DB delete failed.
        # Surface this loudly - it's a real inconsistency for an
        # operator to investigate.
        logger.exception(
            "DB delete failed after audit write for tenant %s obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(
            status_code=500,
            detail="audit_written_but_db_delete_failed",
        )

    if deleted is None:
        # Race: row existed at the snapshot fetch but was gone by the
        # time we tried to delete it. Audit blob already recorded the
        # delete event - call it a successful delete.
        logger.warning(
            "obligation %s for tenant %s was already deleted "
            "between snapshot and delete",
            obligation_id,
            user.tenant_id,
        )

    return {"deleted": True, "obligation": snapshot}


@app.get("/obligations")
def list_obligations(
    user: CurrentUser = Depends(current_user),
    limit: int = 100,
):
    """List regulatory obligations for the caller's tenant.

    tenant_id comes from the verified ID token's custom:tenant_id claim.
    Ordered by due_at ASC NULLS LAST so overdue items surface first,
    then due_soon, then upcoming. Status-based ordering follows so a
    completed task with an old due_at doesn't bubble to the top.
    """
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT
                        o.obligation_id, o.tenant_id, o.device_id,
                        o.title, o.description, o.obligation_type,
                        o.frequency, o.status, o.regulatory_body,
                        o.due_at, o.severity_if_missed,
                        o.responsible_party, o.related_alert_id,
                        o.notes, o.created_at, o.updated_at,
                        o.completed_at,
                        d.brand_name AS device_brand_name,
                        d.di AS device_di
                    FROM obligations o
                    LEFT JOIN devices d ON d.device_id = o.device_id
                    WHERE o.tenant_id = %s
                    ORDER BY
                        CASE o.status
                            WHEN 'overdue' THEN 1
                            WHEN 'due_soon' THEN 2
                            WHEN 'upcoming' THEN 3
                            WHEN 'in_progress' THEN 4
                            WHEN 'completed' THEN 5
                            ELSE 6
                        END ASC,
                        o.due_at ASC NULLS LAST
                    LIMIT %s
                    """,
                    (user.tenant_id, limit),
                )
                rows = cur.fetchall()
        return {
            "tenant_id": user.tenant_id,
            "count": len(rows),
            "obligations": rows,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "list_obligations failed for tenant %s", user.tenant_id
        )
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/obligations/{obligation_id}")
def get_obligation(
    obligation_id: int,
    user: CurrentUser = Depends(current_user),
):
    """Fetch a single obligation by id, scoped to the caller's tenant.

    Cross-tenant lookups return 404, not 403 - same 'unguessable
    response' pattern as /alerts/{alert_id} and /devices/{device_id}.
    """
    try:
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
                    (obligation_id, user.tenant_id),
                )
                row = cur.fetchone()
        if row is None:
            raise HTTPException(
                status_code=404, detail="obligation_not_found"
            )
        return row
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "get_obligation failed for tenant %s, obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/search")
def search_endpoint(
    q: str,
    user: CurrentUser = Depends(current_user),
    limit: int = 10,
):
    """Cross-table full-text search across alerts, devices, obligations.

    Uses Postgres tsvector + GIN index for indexed lookup. Each table
    contributes rows with a normalised shape (kind/id/title/subtitle/url/
    rank) so the UI can render a flat dropdown. ts_rank is used to sort
    results across tables by relevance, not by recency.

    Tenant scoping is enforced on every UNION arm. The q parameter is
    safely converted to a tsquery via plainto_tsquery, so user input
    cannot inject tsquery operators.
    """
    q_clean = (q or "").strip()
    if not q_clean:
        return {"query": "", "results": [], "count": 0}
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT * FROM (
                        SELECT
                            'alert'::text                       AS kind,
                            alert_id::bigint                    AS id,
                            title                               AS title,
                            COALESCE(summary, source)           AS subtitle,
                            ('/alerts/' || alert_id)::text      AS url,
                            urgency                             AS badge,
                            ts_rank(search_vector, plainto_tsquery('english', %s)) AS rank
                        FROM alerts
                        WHERE tenant_id = %s
                          AND search_vector @@ plainto_tsquery('english', %s)

                        UNION ALL

                        SELECT
                            'device'::text                      AS kind,
                            device_id::bigint                   AS id,
                            brand_name                          AS title,
                            manufacturer                        AS subtitle,
                            '/devices'::text                    AS url,
                            device_class                        AS badge,
                            ts_rank(search_vector, plainto_tsquery('english', %s)) AS rank
                        FROM devices
                        WHERE tenant_id = %s
                          AND search_vector @@ plainto_tsquery('english', %s)

                        UNION ALL

                        SELECT
                            'obligation'::text                  AS kind,
                            obligation_id::bigint               AS id,
                            title                               AS title,
                            COALESCE(obligation_type, '')       AS subtitle,
                            '/obligations'::text                AS url,
                            status                              AS badge,
                            ts_rank(search_vector, plainto_tsquery('english', %s)) AS rank
                        FROM obligations
                        WHERE tenant_id = %s
                          AND search_vector @@ plainto_tsquery('english', %s)
                    ) results
                    ORDER BY rank DESC, title ASC
                    LIMIT %s
                    """,
                    (
                        q_clean, user.tenant_id, q_clean,
                        q_clean, user.tenant_id, q_clean,
                        q_clean, user.tenant_id, q_clean,
                        limit,
                    ),
                )
                rows = cur.fetchall()
        # ts_rank returns a float; ensure JSON-safe.
        for r in rows:
            r["rank"] = float(r["rank"]) if r.get("rank") is not None else 0.0
        return {
            "query": q_clean,
            "count": len(rows),
            "results": rows,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "search failed for tenant %s, query %r",
            user.tenant_id,
            q_clean,
        )
        raise HTTPException(status_code=500, detail=str(e))
