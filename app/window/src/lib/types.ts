// Shared alert types.
//
// The shape mirrors what the Brain /alerts endpoint returns (with
// psycopg dict_row rows). Keep this file as the single source of truth -
// the placeholder dataset, the BFF, and the page components all import
// from here so a schema change ripples through type-checking.

export type Classification = "RELEVANT" | "NEEDS_REVIEW" | "NOT_RELEVANT"
export type Urgency = "CRITICAL" | "HIGH" | "MEDIUM" | "LOW"

// The list endpoint returns a trimmed projection of the Alert row.
// The detail endpoint returns the full Alert row.
export interface AlertListItem {
  alert_id: string
  tenant_id: string
  source: string
  external_id: string
  title: string
  classification: Classification
  urgency: Urgency
  relevance_score: number | null
  product_categories: string[] | null
  classified_at: string // ISO 8601 from Postgres
}

export interface AlertDetail extends AlertListItem {
  // Detail rows include everything in the alerts table. Optional fields
  // because not every alert has every column populated.
  summary?: string | null
  url?: string | null
  body?: string | null
  source_url?: string | null
  reasoning?: string | null
  audit_path?: string | null
  audit_version_id?: string | null
  kms_key_alias?: string | null
  created_at?: string | null
  updated_at?: string | null
}

export interface AlertsListResponse {
  tenant_id: string
  count: number
  alerts: AlertListItem[]
}

// Error envelope returned by the BFF when something goes wrong.
// Frontend code can switch on `error` to render a useful message.
export interface BffError {
  error:
    | "unauthenticated"
    | "upstream_unauthorized"
    | "not_found"
    | "upstream_unreachable"
    | "upstream_error"
    | "internal_error"
  status: number
  details?: string
}

// --- Audit log types -----------------------------------------------------
//
// The Brain's /audit endpoint returns one entry per immutable JSON blob
// written to S3 by the worker after classification. Each blob is the
// auditable record of "we saw item X from source Y, classified it as Z."
//
// Shape mirrors AWS CloudTrail LookupEvents and Fastio audit log APIs:
// events list + cursor envelope.

export interface AuditEventSummary {
  /** Opaque URL-safe base64 of the S3 key. Use as path param to detail
   * endpoint (Phase 5A.2). */
  audit_id: string
  /** ISO 8601 timestamp recorded inside the audit blob. */
  audit_timestamp: string
  /** Watcher source, e.g. 'health-canada-medeffect'. */
  source: string
  /** Upstream item id from the source. */
  external_id: string
  /** Item title at time of classification. */
  title: string
  /** Classifier verdict. Same vocabulary as alerts. */
  classification: Classification | "" | string
  /** Urgency band. Same vocabulary as alerts. */
  urgency: Urgency | "" | string
  /** Audit blob size in bytes. */
  size_bytes: number
  /** ISO 8601 timestamp from S3 object LastModified. */
  last_modified: string
  /** KMS key id the object was encrypted under. Short uuid form. */
  encryption_key_id: string | null
}

export interface AuditListResponse {
  events: AuditEventSummary[]
  next_cursor: string | null
  has_more: boolean
}

// --- Device catalog types -----------------------------------------------
//
// The Brain's /devices endpoint returns one entry per medical device a
// distributor handles. Field selection follows FDA UDI conventions plus
// Health Canada MDL data points - the regulators a Canadian distributor
// actually reports to. Stored in the same RDS Postgres as alerts;
// tenant-scoped on every read.

export type DeviceClass = "I" | "II" | "III" | "IV"
export type DeviceStatus =
  | "active"
  | "recalled"
  | "discontinued"
  | "pending"

export interface DeviceListItem {
  device_id: number
  tenant_id: string
  /** UDI-DI: the globally unique device identifier. Distinct from
   * device_id, which is our internal Postgres primary key. */
  di: string
  brand_name: string
  model_number: string | null
  manufacturer: string
  /** Health Canada Medical Device Licence number, if held. */
  mdl_number: string | null
  device_class: DeviceClass | string
  status: DeviceStatus | string
  /** Regulatory clearance type: 510(k), PMA, De Novo, MDL, CE. */
  clearance_type: string | null
  product_categories: string[] | null
  notes: string | null
  created_at: string
  updated_at: string
}

export interface DevicesListResponse {
  tenant_id: string
  count: number
  devices: DeviceListItem[]
}
