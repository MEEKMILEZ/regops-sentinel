"""PostgreSQL connection pool and schema initialization."""
import psycopg
from psycopg.rows import dict_row
import logging
from .config import get_db_credentials

logger = logging.getLogger(__name__)

_pool = None


def get_connection():
    creds = get_db_credentials()
    return psycopg.connect(
        host=creds["host"],
        port=creds["port"],
        dbname=creds["dbname"],
        user=creds["username"],
        password=creds["password"],
        sslmode="require",
        row_factory=dict_row
    )


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS tenants (
    tenant_id      TEXT PRIMARY KEY,
    display_name   TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS alerts (
    alert_id           BIGSERIAL PRIMARY KEY,
    tenant_id          TEXT NOT NULL REFERENCES tenants(tenant_id),
    source             TEXT NOT NULL,
    external_id        TEXT NOT NULL,
    title              TEXT NOT NULL,
    summary            TEXT,
    url                TEXT,
    classification     TEXT NOT NULL,
    relevance_score    NUMERIC(3,2),
    urgency            TEXT NOT NULL,
    product_categories TEXT[],
    raw_payload        JSONB NOT NULL,
    classified_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    fetched_at         TIMESTAMPTZ,
    UNIQUE (tenant_id, source, external_id)
);

CREATE INDEX IF NOT EXISTS idx_alerts_tenant_classified
    ON alerts (tenant_id, classified_at DESC);

CREATE INDEX IF NOT EXISTS idx_alerts_urgency
    ON alerts (tenant_id, urgency)
    WHERE urgency IN ('CRITICAL', 'HIGH');

INSERT INTO tenants (tenant_id, display_name)
VALUES
    ('tenant-acme-meddev', 'Acme MedDev (fictional)'),
    ('tenant-globex-medical', 'Globex Medical (fictional)')
ON CONFLICT (tenant_id) DO NOTHING;
"""


def init_schema():
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(SCHEMA_SQL)
        conn.commit()
    logger.info("Database schema initialized")