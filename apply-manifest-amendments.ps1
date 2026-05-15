# apply-manifest-amendments.ps1
# Adds amendment rows to SCREENSHOTS-MANIFEST.md for screenshots
# touched by Phase 5A sprint:
#   - Row 34, 35: deferred to later phases
#   - Row 36: captured (Phase 5A audit log UI shipped)
#   - Row 37, 38, 44: deferred
#
# Per the manifest's own rules: filenames and capture order remain
# locked. Only the "Manifest amendments" table is modified.

$ErrorActionPreference = "Stop"

$manifest = "SCREENSHOTS-MANIFEST.md"

if (-not (Test-Path $manifest)) {
    Write-Error "SCREENSHOTS-MANIFEST.md not found at repo root"
    exit 1
}

$content = Get-Content $manifest -Raw

# Idempotency: check if our amendment date already appears
if ($content -match "2026-05-14 \| 36 \| Captured") {
    Write-Host "Phase 5A amendment rows already present - skipping"
    exit 0
}

# Anchor: insert just before the "Phase 5 pending work" section.
# This puts the new rows at the bottom of the amendments table,
# chronologically after the 2026-05-09 row that already exists.

$anchor = "## Phase 5 pending work (audit bucket hardening)"

if ($content -notmatch [regex]::Escape($anchor)) {
    Write-Error "Could not find 'Phase 5 pending work' section anchor"
    exit 1
}

$amendments = @'
| 2026-05-14 | 34 | Deferred to Phase 5C | Obligations tracker (`34-app-window-obligation-tracker.png`) is a real domain feature requiring its own engineering sprint (~8-10hr). Phase 5C committed for the weeks ahead. Capture when the feature ships. |
| 2026-05-14 | 35 | Deferred to Phase 5B | Device catalog upload UI (`35-app-window-device-catalog.png`) is a real domain feature requiring its own engineering sprint (~8-10hr). Phase 5B committed for the weeks ahead. Capture when the feature ships. |
| 2026-05-14 | 36 | Captured (Phase 5A shipped) | Audit log UI shipped 2026-05-14 evening. Brain `GET /audit` endpoint with cursor pagination + multi-audience Cognito JWT verification (web + CLI clients). Window `/audit` server component + BFF proxy + sidebar nav entry. End-to-end validated: 84 audit blobs across 2 pages, tenant scoping verified via S3 prefix derived from JWT claim. Screenshot captured against real RDS-backed data. |
| 2026-05-14 | 37 | Deferred | Tenant isolation proof requires seeding a second Cognito tenant + RDS rows under a separate tenant_id, then side-by-side browser capture. Tenant scoping is verified architecturally (Brain derives S3 prefix from JWT claim, never trusts query input) but visual proof needs a second tenant. Out of scope for the Phase 5A sprint; revisit during Phase 5+ polish. |
| 2026-05-14 | 38 | Deferred | Mobile responsiveness not currently tested or optimised. Page layouts use Tailwind sm:/lg: breakpoints but no specific mobile audit has been performed. Revisit during Phase 5+ polish. |
| 2026-05-14 | 44 | Deferred (capture only) | CloudWatch dashboard infrastructure deployed (commit da0fa9a). Screenshot deferred until meaningful traffic populates widgets - a flat-line screenshot would mislead. Recapture once Phase 5B/5C are live and generating sustained load. |

'@

# Insert the new rows immediately before the anchor section header
$content = $content -replace [regex]::Escape($anchor), ($amendments + $anchor)

Set-Content -Path $manifest -Value $content -NoNewline

Write-Host "Manifest amendments added. Verify:"
Write-Host ""
Get-Content $manifest | Select-String -Pattern "2026-05-14" | Select-Object LineNumber, Line | Format-Table -AutoSize
