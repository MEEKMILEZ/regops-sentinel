// Shared alert types.
//
// The shape mirrors what the Brain /alerts endpoint returns (with
// psycopg dict_row rows). Keep this file as the single source of truth -
// the placeholder dataset, the BFF, and the page components all import
// from here so a schema change ripples through type-checking.

export type Classification = "RELEVANT" | "NEEDS_REVIEW" | "NOT_RELEVANT"
export type Urgency = "CRITICAL" | "HIGH" | "MEDIUM" | "LOW"

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
  classified_at: string
}

export interface AlertDetail extends AlertListItem {
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

export interface AuditEventSummary {
  audit_id: string
  audit_timestamp: string
  source: string
  external_id: string
  title: string
  classification: Classification | "" | string
  urgency: Urgency | "" | string
  size_bytes: number
  last_modified: string
  encryption_key_id: string | null
}

export interface AuditListResponse {
  events: AuditEventSummary[]
  next_cursor: string | null
  has_more: boolean
}

// --- Device catalog types -----------------------------------------------

export type DeviceClass = "I" | "II" | "III" | "IV"
export type DeviceStatus =
  | "active"
  | "recalled"
  | "discontinued"
  | "pending"

export interface DeviceListItem {
  device_id: number
  tenant_id: string
  di: string
  brand_name: string
  model_number: string | null
  manufacturer: string
  mdl_number: string | null
  device_class: DeviceClass | string
  status: DeviceStatus | string
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

// --- Device upload job types (Phase 5B.2) -------------------------------
//
// The Brain's POST /devices/upload accepts a CSV body and returns a
// job_id immediately. The actual ingestion happens in a background
// worker. Callers poll GET /devices/upload/{job_id} for progress.
//
// status state machine:
//   queued     -> just created, worker hasn't started yet
//   processing -> worker is parsing/inserting rows
//   complete   -> all rows processed (some may have failed; check
//                 error_count for per-row errors)
//   failed     -> worker itself crashed before completion; failure_reason
//                 will be set

export type DeviceUploadJobStatus =
  | "queued"
  | "processing"
  | "complete"
  | "failed"

export interface DeviceUploadJobErrorEntry {
  row: number
  di: string | null
  error: string
}

export interface DeviceUploadJobCreateResponse {
  job_id: string
  status: DeviceUploadJobStatus
}

export interface DeviceUploadJob {
  job_id: string
  tenant_id: string
  status: DeviceUploadJobStatus
  filename: string | null
  total_rows: number
  processed_rows: number
  inserted_count: number
  updated_count: number
  error_count: number
  error_log: DeviceUploadJobErrorEntry[]
  failure_reason: string | null
  created_at: string
  started_at: string | null
  completed_at: string | null
}

// --- Obligation types ---------------------------------------------------

export type ObligationType =
  | "mdl_renewal"
  | "adverse_event_report"
  | "recall_notification"
  | "qms_audit"
  | "post_market_surveillance"
  | "udi_submission"
  | "incident_investigation"

export type ObligationFrequency =
  | "one_time"
  | "annual"
  | "quarterly"
  | "monthly"
  | "as_required"

export type ObligationStatus =
  | "upcoming"
  | "due_soon"
  | "overdue"
  | "in_progress"
  | "completed"
  | "not_applicable"

export type ObligationSeverity = "critical" | "high" | "medium" | "low"

export type RegulatoryBody =
  | "health_canada"
  | "fda"
  | "iso_auditor"
  | "internal_qms"

export interface ObligationListItem {
  obligation_id: number
  tenant_id: string
  device_id: number | null
  title: string
  description: string | null
  obligation_type: ObligationType | string
  frequency: ObligationFrequency | string
  status: ObligationStatus | string
  regulatory_body: RegulatoryBody | string | null
  due_at: string | null
  severity_if_missed: ObligationSeverity | string
  responsible_party: string | null
  related_alert_id: number | null
  notes: string | null
  created_at: string
  updated_at: string
  completed_at: string | null
  device_brand_name: string | null
  device_di: string | null
}

export interface ObligationsListResponse {
  tenant_id: string
  count: number
  obligations: ObligationListItem[]
}

// --- Cross-table search types -------------------------------------------

export type SearchKind = "alert" | "device" | "obligation"

export interface SearchResultItem {
  kind: SearchKind | string
  id: number
  title: string
  subtitle: string | null
  url: string
  badge: string | null
  rank: number
}

export interface SearchResponse {
  query: string
  count: number
  results: SearchResultItem[]
}
