# apply-obligations-window-patches.ps1
# Three changes:
#   1. types.ts: append ObligationListItem + ObligationsListResponse
#   2. app-sidebar.tsx: add ClipboardList icon + "Obligations" nav entry
#   3. site-header.tsx: hide the stub search bar (it has no backend)

$ErrorActionPreference = "Stop"

# --- Patch 1: types.ts append ---
$typesFile = "app\window\src\lib\types.ts"
$tcontent = Get-Content $typesFile -Raw

if ($tcontent -match "ObligationListItem") {
    Write-Host "Obligations types already in types.ts - skipping patch 1"
} else {
    $obTypes = @'


// --- Obligation types ---------------------------------------------------
//
// The Brain's /obligations endpoint returns one entry per regulatory
// task a compliance lead must track. Schema mirrors Health Canada CMDR
// Section 60 reporting requirements + ISO 13485 quality management
// obligations + FDA UDI submission cycles.
//
// device_id is nullable: some obligations are device-specific (MDL
// renewal for a particular product), others are company-wide (annual
// ISO 13485 internal audit). When device_id is set, the Brain also
// joins the device record so the UI can show the brand name without a
// second fetch.

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
  /** ISO 8601 timestamp. NULL for as_required obligations. */
  due_at: string | null
  severity_if_missed: ObligationSeverity | string
  responsible_party: string | null
  related_alert_id: number | null
  notes: string | null
  created_at: string
  updated_at: string
  completed_at: string | null
  /** Joined from devices table when device_id is set. */
  device_brand_name: string | null
  device_di: string | null
}

export interface ObligationsListResponse {
  tenant_id: string
  count: number
  obligations: ObligationListItem[]
}
'@

    $tcontent = $tcontent.TrimEnd() + $obTypes + "`r`n"
    Set-Content -Path $typesFile -Value $tcontent -NoNewline
    Write-Host "types.ts patched: ObligationListItem + ObligationsListResponse appended"
}

# --- Patch 2: app-sidebar.tsx ---
$sidebar = "app\window\src\components\app-sidebar.tsx"
$scontent = Get-Content $sidebar -Raw

if ($scontent -match '"Obligations".*"/obligations"') {
    Write-Host "Obligations nav entry already in app-sidebar.tsx - skipping patch 2"
} else {
    # 2a: Add ClipboardList to lucide import
    $oldImport = @'
import {
  LayoutDashboard,
  Bell,
  FileText,
  Boxes,
  Shield,
  Settings,
  LogOut,
  ChevronUp,
  User,
} from "lucide-react"
'@
    $newImport = @'
import {
  LayoutDashboard,
  Bell,
  FileText,
  Boxes,
  ClipboardList,
  Shield,
  Settings,
  LogOut,
  ChevronUp,
  User,
} from "lucide-react"
'@
    if ($scontent -notmatch [regex]::Escape($oldImport)) {
        Write-Error "Could not find lucide import anchor in app-sidebar.tsx"
        exit 1
    }
    $scontent = $scontent -replace [regex]::Escape($oldImport), $newImport

    # 2b: Update the nav-items comment - all four pages now exist
    $oldComment = @'
// Navigation items shown in the main sidebar group.
// Only routes that are actually wired and gated render here. Obligations
// remains intentionally omitted until Phase 5C ships; showing a link
// that 404s would be worse than not showing it at all. Audit log
// shipped in Phase 5A, Devices catalog (read-only) shipped in Phase 5B.
'@
    $newComment = @'
// Navigation items shown in the main sidebar group. Audit log shipped
// in Phase 5A, Devices catalog (read-only) in Phase 5B, Obligations
// tracker (read-only) in Phase 5C. All four routes are wired and
// tenant-gated by Cognito middleware + Brain JWT verification.
'@
    if ($scontent -notmatch [regex]::Escape($oldComment)) {
        Write-Error "Could not find navItems comment anchor in app-sidebar.tsx"
        exit 1
    }
    $scontent = $scontent -replace [regex]::Escape($oldComment), $newComment

    # 2c: Add Obligations entry to navItems (insert between Alerts and Devices for workflow order: monitor -> inventory -> commitments -> trail)
    $oldNav = @'
const navItems = [
  { title: "Dashboard", url: "/", icon: LayoutDashboard },
  { title: "Alerts", url: "/alerts", icon: Bell },
  { title: "Devices", url: "/devices", icon: Boxes },
  { title: "Audit log", url: "/audit", icon: FileText },
]
'@
    $newNav = @'
const navItems = [
  { title: "Dashboard", url: "/", icon: LayoutDashboard },
  { title: "Alerts", url: "/alerts", icon: Bell },
  { title: "Devices", url: "/devices", icon: Boxes },
  { title: "Obligations", url: "/obligations", icon: ClipboardList },
  { title: "Audit log", url: "/audit", icon: FileText },
]
'@
    if ($scontent -notmatch [regex]::Escape($oldNav)) {
        Write-Error "Could not find navItems array anchor in app-sidebar.tsx"
        exit 1
    }
    $scontent = $scontent -replace [regex]::Escape($oldNav), $newNav

    Set-Content -Path $sidebar -Value $scontent -NoNewline
    Write-Host "app-sidebar.tsx patched: ClipboardList icon + Obligations entry added"
}

# --- Patch 3: site-header.tsx - hide stub search bar ---
$header = "app\window\src\components\site-header.tsx"
$hcontent = Get-Content $header -Raw

if ($hcontent -match "// Stub search bar hidden") {
    Write-Host "site-header.tsx search bar already removed - skipping patch 3"
} else {
    $oldSearch = @'
      <div className="ml-auto flex w-full max-w-sm items-center gap-2">
        <div className="relative w-full">
          <Search className="text-muted-foreground absolute top-1/2 left-2.5 size-4 -translate-y-1/2" />
          <Input
            placeholder="Search alerts, devices..."
            className="w-full pl-8"
          />
        </div>
      </div>
'@
    $newSearch = @'
      {/* Stub search bar hidden until full-text search ships (see backlog).
          Showing a non-functional search box is worse than not showing one. */}
'@
    if ($hcontent -notmatch [regex]::Escape($oldSearch)) {
        Write-Error "Could not find search bar anchor in site-header.tsx"
        exit 1
    }
    $hcontent = $hcontent -replace [regex]::Escape($oldSearch), $newSearch

    # Also drop the now-unused Search + Input imports to avoid TypeScript
    # "declared but never used" errors.
    $hcontent = $hcontent -replace 'import \{ Search \} from "lucide-react"\r?\n', ''
    $hcontent = $hcontent -replace 'import \{ Input \} from "@/components/ui/input"\r?\n', ''

    Set-Content -Path $header -Value $hcontent -NoNewline
    Write-Host "site-header.tsx patched: stub search bar removed"
}

# --- Verify ---
Write-Host ""
Write-Host "--- Verify types.ts ---"
Get-Content $typesFile | Select-String -Pattern "ObligationListItem|ObligationsListResponse|ObligationType" | Select-Object LineNumber, Line | Format-Table -AutoSize

Write-Host "--- Verify app-sidebar.tsx ---"
Get-Content $sidebar | Select-String -Pattern "ClipboardList|/obligations|Obligations" | Select-Object LineNumber, Line | Format-Table -AutoSize

Write-Host "--- Verify site-header.tsx ---"
Get-Content $header | Select-String -Pattern "Search|Input|Stub search" | Select-Object LineNumber, Line | Format-Table -AutoSize
