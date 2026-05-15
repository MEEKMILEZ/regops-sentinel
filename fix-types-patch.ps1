# fix-types-patch.ps1
# Two changes to app/window/src/lib/types.ts:
#   1. Add `summary` and `url` to AlertDetail (referenced by alerts/[id]/page.tsx)
#   2. Append AuditEventSummary and AuditListResponse interfaces
#
# Both patches are surgical: anchored on exact strings, additions only,
# no other content touched.

$ErrorActionPreference = "Stop"

$typesFile = "app\window\src\lib\types.ts"
$content = Get-Content $typesFile -Raw

# --- Patch 1: AlertDetail - add summary + url ---

if ($content -match "summary\?:\s*string \| null") {
    Write-Host "AlertDetail already has summary - skipping patch 1"
} else {
    $anchor = "export interface AlertDetail extends AlertListItem {`r`n  // Detail rows include everything in the alerts table. Optional fields`r`n  // because not every alert has every column populated.`r`n  body?: string | null"

    # Try CRLF first; fall back to LF
    $foundAnchor = $null
    foreach ($le in @("`r`n", "`n")) {
        $tryAnchor = "export interface AlertDetail extends AlertListItem {$($le)  // Detail rows include everything in the alerts table. Optional fields$($le)  // because not every alert has every column populated.$($le)  body?: string | null"
        if ($content -match [regex]::Escape($tryAnchor)) {
            $foundAnchor = $tryAnchor
            $le_found = $le
            break
        }
    }

    if (-not $foundAnchor) {
        Write-Error "Could not find AlertDetail anchor in types.ts"
        exit 1
    }

    $replacement = "export interface AlertDetail extends AlertListItem {$($le_found)  // Detail rows include everything in the alerts table. Optional fields$($le_found)  // because not every alert has every column populated.$($le_found)  summary?: string | null$($le_found)  url?: string | null$($le_found)  body?: string | null"

    $content = $content -replace [regex]::Escape($foundAnchor), $replacement
    Write-Host "Patch 1 applied: AlertDetail.summary and AlertDetail.url added"
}

# --- Patch 2: append audit types at end of file ---

if ($content -match "AuditEventSummary") {
    Write-Host "Audit types already present - skipping patch 2"
} else {
    # Anchor on the closing brace of BffError + final newline
    $bffErrorBlock = "export interface BffError {"
    if ($content -notmatch [regex]::Escape($bffErrorBlock)) {
        Write-Error "Could not find BffError block in types.ts"
        exit 1
    }

    $audit = @'


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
'@

    # Append at very end of file (after the closing brace of BffError)
    $content = $content.TrimEnd() + $audit + "`r`n"
    Write-Host "Patch 2 applied: AuditEventSummary and AuditListResponse appended"
}

Set-Content -Path $typesFile -Value $content -NoNewline

# --- Verify ---
Write-Host ""
Write-Host "--- Verify ---"
$verifyContent = Get-Content $typesFile -Raw
$checks = @(
    @{ name = "AlertDetail.summary"; pattern = "summary\?:\s*string \| null" }
    @{ name = "AlertDetail.url";     pattern = "url\?:\s*string \| null" }
    @{ name = "AuditEventSummary";   pattern = "export interface AuditEventSummary" }
    @{ name = "AuditListResponse";   pattern = "export interface AuditListResponse" }
)
foreach ($c in $checks) {
    if ($verifyContent -match $c.pattern) {
        Write-Host "    OK  : $($c.name)"
    } else {
        Write-Host "    MISS: $($c.name)"
    }
}

Write-Host ""
Write-Host "Next: cmd /c `"npm run build`" from app/window"
