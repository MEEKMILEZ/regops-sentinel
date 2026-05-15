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
