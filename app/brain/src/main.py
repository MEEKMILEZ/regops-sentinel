"""FastAPI app exposing health checks and a manual classification endpoint.
The SQS worker runs in a background thread."""
import logging
import os
import threading
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from .config import LOG_LEVEL
from .db import init_schema, get_connection
from .worker import poll_loop, process_message
from .classifier import classify
from .config import get_azure_openai_credentials

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


app = FastAPI(title="RegOps Sentinel Brain", version="0.1.0", lifespan=lifespan)


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
        deployment_name = get_azure_openai_credentials().get("deployment_name", "gpt-4o-regops")
        result = classify(req.model_dump(), deployment_name)
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/alerts")
def list_alerts(tenant_id: str = "tenant-acme-meddev", limit: int = 50):
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    SELECT alert_id, tenant_id, source, external_id, title,
                           classification, urgency, relevance_score,
                           product_categories, classified_at
                    FROM alerts
                    WHERE tenant_id = %s
                    ORDER BY classified_at DESC
                    LIMIT %s
                """, (tenant_id, limit))
                rows = cur.fetchall()
        return {"tenant_id": tenant_id, "count": len(rows), "alerts": rows}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))