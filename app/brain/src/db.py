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

CREATE TABLE IF NOT EXISTS devices (
    device_id           BIGSERIAL PRIMARY KEY,
    tenant_id           TEXT NOT NULL REFERENCES tenants(tenant_id),
    di                  TEXT NOT NULL,
    brand_name          TEXT NOT NULL,
    model_number        TEXT,
    manufacturer        TEXT NOT NULL,
    mdl_number          TEXT,
    device_class        TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'active',
    clearance_type      TEXT,
    product_categories  TEXT[],
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (tenant_id, di)
);

CREATE INDEX IF NOT EXISTS idx_devices_tenant_status
    ON devices (tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_devices_tenant_class
    ON devices (tenant_id, device_class);

CREATE TABLE IF NOT EXISTS obligations (
    obligation_id       BIGSERIAL PRIMARY KEY,
    tenant_id           TEXT NOT NULL REFERENCES tenants(tenant_id),
    device_id           BIGINT REFERENCES devices(device_id),
    title               TEXT NOT NULL,
    description         TEXT,
    obligation_type     TEXT NOT NULL,
    frequency           TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'upcoming',
    regulatory_body     TEXT,
    due_at              TIMESTAMPTZ,
    severity_if_missed  TEXT NOT NULL DEFAULT 'medium',
    responsible_party   TEXT,
    related_alert_id    BIGINT REFERENCES alerts(alert_id),
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_obligations_tenant_due
    ON obligations (tenant_id, due_at ASC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_obligations_tenant_status
    ON obligations (tenant_id, status)
    WHERE status IN ('overdue', 'due_soon', 'upcoming');

-- pgcrypto required for gen_random_uuid() used by device_upload_jobs.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE alerts
    ADD COLUMN IF NOT EXISTS search_vector tsvector;

ALTER TABLE devices
    ADD COLUMN IF NOT EXISTS search_vector tsvector;

ALTER TABLE obligations
    ADD COLUMN IF NOT EXISTS search_vector tsvector;

CREATE OR REPLACE FUNCTION alerts_search_vector_trigger()
    RETURNS trigger AS $$
BEGIN
    NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.summary, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(NEW.source, '')), 'C');
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_alerts_search_vector ON alerts;
CREATE TRIGGER trg_alerts_search_vector
    BEFORE INSERT OR UPDATE OF title, summary, source ON alerts
    FOR EACH ROW EXECUTE FUNCTION alerts_search_vector_trigger();

CREATE OR REPLACE FUNCTION devices_search_vector_trigger()
    RETURNS trigger AS $$
BEGIN
    NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.brand_name, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.manufacturer, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(NEW.model_number, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(NEW.di, '')), 'C') ||
        setweight(to_tsvector('english', coalesce(NEW.mdl_number, '')), 'C');
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_devices_search_vector ON devices;
CREATE TRIGGER trg_devices_search_vector
    BEFORE INSERT OR UPDATE OF brand_name, manufacturer, model_number, di, mdl_number ON devices
    FOR EACH ROW EXECUTE FUNCTION devices_search_vector_trigger();

CREATE OR REPLACE FUNCTION obligations_search_vector_trigger()
    RETURNS trigger AS $$
BEGIN
    NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(NEW.obligation_type, '')), 'C') ||
        setweight(to_tsvector('english', coalesce(NEW.responsible_party, '')), 'C');
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_obligations_search_vector ON obligations;
CREATE TRIGGER trg_obligations_search_vector
    BEFORE INSERT OR UPDATE OF title, description, obligation_type, responsible_party ON obligations
    FOR EACH ROW EXECUTE FUNCTION obligations_search_vector_trigger();

CREATE INDEX IF NOT EXISTS idx_alerts_search ON alerts USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_devices_search ON devices USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_obligations_search ON obligations USING GIN(search_vector);

UPDATE alerts SET title = title WHERE search_vector IS NULL;
UPDATE devices SET brand_name = brand_name WHERE search_vector IS NULL;
UPDATE obligations SET title = title WHERE search_vector IS NULL;

-- =====================================================================
-- Phase 5B.2: device_upload_jobs table (async CSV ingestion)
-- =====================================================================
--
-- Industry-standard async job pattern:
--   1. Client POST /devices/upload with CSV body, gets back job_id
--   2. Job row created status=queued, payload stored in payload_csv
--   3. Background thread picks up, sets status=processing
--   4. Worker parses CSV, processes rows in batches, updates counts
--   5. On completion sets status=complete (or failed) + completed_at
--   6. Client polls GET /devices/upload/{job_id} for progress
--
-- Same pattern as S3 Batch Operations, Stripe File Uploads, Shopify
-- Bulk Operations.

CREATE TABLE IF NOT EXISTS device_upload_jobs (
    job_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       TEXT NOT NULL REFERENCES tenants(tenant_id),
    status          TEXT NOT NULL DEFAULT 'queued',
    filename        TEXT,
    payload_csv     TEXT NOT NULL,
    total_rows      INTEGER NOT NULL DEFAULT 0,
    processed_rows  INTEGER NOT NULL DEFAULT 0,
    inserted_count  INTEGER NOT NULL DEFAULT 0,
    updated_count   INTEGER NOT NULL DEFAULT 0,
    error_count     INTEGER NOT NULL DEFAULT 0,
    error_log       JSONB NOT NULL DEFAULT '[]'::jsonb,
    failure_reason  TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_device_upload_jobs_tenant_created
    ON device_upload_jobs (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_device_upload_jobs_status
    ON device_upload_jobs (status)
    WHERE status IN ('queued', 'processing');

INSERT INTO tenants (tenant_id, display_name)
VALUES
    ('tenant-acme-meddev', 'Acme MedDev (fictional)'),
    ('tenant-globex-medical', 'Globex Medical (fictional)')
ON CONFLICT (tenant_id) DO NOTHING;

INSERT INTO devices (
    tenant_id, di, brand_name, model_number, manufacturer,
    mdl_number, device_class, status, clearance_type, product_categories
)
VALUES
    ('tenant-acme-meddev', '00819320020014', 'Impella CP', '0048-0001',
     'Abiomed, Inc.', '105432', 'IV', 'recalled', 'PMA',
     ARRAY['cardiology-devices','circulatory-support']),
    ('tenant-acme-meddev', '00819320020021', 'CASE Cardiac Testing System',
     'V8.0', 'GE HealthCare', '78812', 'II', 'active', '510(k)',
     ARRAY['cardiology-devices','diagnostic-ecg']),
    ('tenant-acme-meddev', '00819320020038', 'directCHECK Whole Blood Control',
     'WB-CTRL-100', 'Werfen', '54321', 'I', 'active', 'MDL',
     ARRAY['ivd-quality-control']),
    ('tenant-acme-meddev', '00819320020045', 'Endoflip System',
     'EF-322', 'Medtronic', '92110', 'II', 'active', '510(k)',
     ARRAY['gastroenterology','functional-luminal-imaging']),
    ('tenant-acme-meddev', '00819320020052', 'Plum Solo Infusion Pump',
     '30010', 'ICU Medical', '88445', 'II', 'recalled', '510(k)',
     ARRAY['infusion-therapy']),
    ('tenant-acme-meddev', '00819320020069', 'Plum Duo Precision IV Pump',
     '30020', 'ICU Medical', '88446', 'II', 'recalled', '510(k)',
     ARRAY['infusion-therapy']),
    ('tenant-acme-meddev', '00819320020076', 'Avanta Fluid Injection System',
     'AV-2200', 'Bracco Diagnostics', '67891', 'II', 'recalled', '510(k)',
     ARRAY['contrast-injection','radiology']),
    ('tenant-acme-meddev', '00819320020083', 'Azurion Image-Guided Therapy',
     'C20', 'Philips', '110234', 'III', 'active', 'MDL',
     ARRAY['interventional-radiology','imaging']),
    ('tenant-acme-meddev', '00819320020090', 'TCN Reusable RF Electrodes',
     'TCN-RFE-5', 'Stryker', '99012', 'II', 'active', '510(k)',
     ARRAY['surgical-energy','electrosurgery']),
    ('tenant-acme-meddev', '00819320020106', 'GlucoMeter Pro 200',
     'GM-PRO-200', 'Abbott Diabetes Care', '45678', 'II', 'active', 'MDL',
     ARRAY['ivd-glucose','point-of-care']),
    ('tenant-acme-meddev', '00819320020113', 'NeuroVent EEG Cap',
     'NV-EEG-32', 'Natus Medical', '55321', 'II', 'active', '510(k)',
     ARRAY['neurology','eeg-monitoring']),
    ('tenant-acme-meddev', '00819320020120', 'SurgiSeal Tissue Adhesive',
     'SS-TA-2', 'Adhezion Biomedical', '70044', 'II', 'discontinued', 'MDL',
     ARRAY['wound-closure','surgical-adhesives'])
ON CONFLICT (tenant_id, di) DO NOTHING;

INSERT INTO obligations (
    tenant_id, device_id, title, description, obligation_type,
    frequency, status, regulatory_body, due_at, severity_if_missed,
    responsible_party
)
SELECT
    'tenant-acme-meddev',
    (SELECT device_id FROM devices WHERE di = src.di LIMIT 1),
    src.title, src.description, src.obligation_type,
    src.frequency, src.status, src.regulatory_body,
    NOW() + (src.due_offset_days || ' days')::INTERVAL,
    src.severity_if_missed, src.responsible_party
FROM (VALUES
    ('00819320020014', 'Recall notification to distributors',
     'Send Impella CP Class IV recall notice to all customer hospitals per FDA 21 CFR 806.10 / Health Canada MDR Section 64.',
     'recall_notification', 'one_time', 'overdue', 'health_canada',
     -2, 'critical', 'Compliance Lead'),
    ('00819320020052', 'Plum Solo recall - customer outreach round 2',
     'Second-wave customer notification for Plum Solo Class II recall. Round 1 complete; round 2 covers non-responders.',
     'recall_notification', 'one_time', 'overdue', 'health_canada',
     -1, 'high', 'Customer Success'),
    ('00819320020069', 'Plum Duo - 30-day update to Health Canada',
     'Required follow-up report 30 days after initial recall filing. Forms: MDR Section 60 update form.',
     'recall_notification', 'one_time', 'due_soon', 'health_canada',
     3, 'high', 'Compliance Lead'),
    (NULL, 'Quarterly adverse event report (Q1 2026)',
     'Aggregate AE report covering all distributed devices for Q1 2026. Combines device-specific AE counts into single CMDR Section 59 quarterly filing.',
     'adverse_event_report', 'quarterly', 'due_soon', 'health_canada',
     5, 'high', 'Compliance Lead'),
    ('00819320020076', 'Avanta - root cause investigation report',
     'Internal RCA for Avanta recall trigger. Required by ISO 13485:2016 clause 8.5.2 before corrective action closure.',
     'incident_investigation', 'one_time', 'due_soon', 'internal_qms',
     6, 'medium', 'Quality Engineer'),
    ('00819320020014', 'Impella CP - MDL renewal',
     'Health Canada Medical Device Licence #105432 expires in 18 days. Renewal application requires updated QMS attestation.',
     'mdl_renewal', 'annual', 'upcoming', 'health_canada',
     18, 'critical', 'Compliance Lead'),
    (NULL, 'ISO 13485 internal audit - Q2 2026',
     'Annual internal QMS audit per ISO 13485:2016 clause 8.2.4. Scheduled for week of June 1.',
     'qms_audit', 'annual', 'upcoming', 'iso_auditor',
     21, 'medium', 'Quality Manager'),
    ('00819320020083', 'Azurion - post-market surveillance review',
     'Annual PMS review for Class III Azurion image-guided therapy system. Required by Health Canada CMDR Section 61.',
     'post_market_surveillance', 'annual', 'upcoming', 'health_canada',
     24, 'medium', 'Compliance Lead'),
    ('00819320020045', 'Endoflip - UDI database submission update',
     'Health Canada UDI database refresh - new model variant added to product line. Submission window opens monthly.',
     'udi_submission', 'monthly', 'upcoming', 'health_canada',
     27, 'low', 'Regulatory Affairs'),
    ('00819320020021', 'CASE Cardiac - manufacturer attestation refresh',
     'Annual confirmation that distributor is still authorised to distribute GE HealthCare devices. Required for MDL active status.',
     'mdl_renewal', 'annual', 'upcoming', 'health_canada',
     45, 'medium', 'Compliance Lead'),
    ('00819320020014', 'Impella CP - initial recall filing',
     'Initial recall notification filed with Health Canada within 72hr of discovery. Filed 2026-04-15.',
     'recall_notification', 'one_time', 'completed', 'health_canada',
     -30, 'critical', 'Compliance Lead'),
    (NULL, 'Annual QMS management review (2025)',
     'Top management review of QMS performance per ISO 13485 clause 5.6. Completed 2026-03-28.',
     'qms_audit', 'annual', 'completed', 'internal_qms',
     -47, 'medium', 'Quality Manager')
) AS src(
    di, title, description, obligation_type, frequency, status,
    regulatory_body, due_offset_days, severity_if_missed, responsible_party
)
WHERE NOT EXISTS (
    SELECT 1 FROM obligations o
    WHERE o.tenant_id = 'tenant-acme-meddev'
      AND o.title = src.title
);

UPDATE obligations
SET completed_at = updated_at
WHERE tenant_id = 'tenant-acme-meddev'
  AND status = 'completed'
  AND completed_at IS NULL;
"""


def init_schema():
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(SCHEMA_SQL)
        conn.commit()
    logger.info("Database schema initialized")
