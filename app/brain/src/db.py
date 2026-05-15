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

-- Devices catalog. One row per medical device a distributor handles.
-- Field selection follows FDA UDI (Unique Device Identification)
-- conventions plus Health Canada MDL (Medical Device Licence) data
-- points - the regulators a Canadian distributor like Acme MedDev
-- actually reports to.
CREATE TABLE IF NOT EXISTS devices (
    device_id           BIGSERIAL PRIMARY KEY,
    tenant_id           TEXT NOT NULL REFERENCES tenants(tenant_id),
    -- Device Identifier (DI) from the UDI: a globally unique code that
    -- identifies the device's model. Distinct from the device_id PK
    -- which is our internal database key.
    di                  TEXT NOT NULL,
    brand_name          TEXT NOT NULL,
    model_number        TEXT,
    manufacturer        TEXT NOT NULL,
    -- Health Canada Medical Device Licence number, if held.
    mdl_number          TEXT,
    -- Device class per Health Canada (I, II, III, IV). FDA uses
    -- I/II/III. We store as TEXT to cover both conventions.
    device_class        TEXT NOT NULL,
    -- Lifecycle status: active, recalled, discontinued, pending.
    status              TEXT NOT NULL DEFAULT 'active',
    -- Regulatory clearance type: 510(k), PMA, De Novo, MDL, CE.
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

INSERT INTO tenants (tenant_id, display_name)
VALUES
    ('tenant-acme-meddev', 'Acme MedDev (fictional)'),
    ('tenant-globex-medical', 'Globex Medical (fictional)')
ON CONFLICT (tenant_id) DO NOTHING;

-- Seed devices for Acme MedDev so the catalog page is never empty in
-- demo/portfolio mode. Real device names with realistic class/MDL
-- combinations modelled on Health Canada's MDALL public database.
-- ON CONFLICT DO NOTHING means re-runs are idempotent and never
-- overwrite real data added through future upload UIs.
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
"""


def init_schema():
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(SCHEMA_SQL)
        conn.commit()
    logger.info("Database schema initialized")
