"""FastAPI app exposing health checks, classification, and alerts.
The SQS worker runs in a background thread."""
import logging
import os
import threading
from contextlib import asynccontextmanager
from fastapi import Depends, FastAPI, HTTPException
from psycopg.rows import dict_row
from pydantic import BaseModel
from .auth import CurrentUser, current_user
from .audit import AuditListResponse, list_audit_events
from .config import LOG_LEVEL, S3_AUDIT_BUCKET, get_azure_openai_credentials
from .db import init_schema, get_connection
from .worker import poll_loop
from .classifier import classify

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
