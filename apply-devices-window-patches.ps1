# apply-devices-window-patches.ps1
# Two changes:
#   1. types.ts: append DeviceListItem + DevicesListResponse interfaces
#   2. app-sidebar.tsx: add Boxes icon + "Devices" nav entry, update comment

$ErrorActionPreference = "Stop"

# --- Patch 1: types.ts append ---
$typesFile = "app\window\src\lib\types.ts"
$tcontent = Get-Content $typesFile -Raw

if ($tcontent -match "DeviceListItem") {
    Write-Host "Devices types already in types.ts - skipping patch 1"
} else {
    $deviceTypes = @'


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
'@

    $tcontent = $tcontent.TrimEnd() + $deviceTypes + "`r`n"
    Set-Content -Path $typesFile -Value $tcontent -NoNewline
    Write-Host "types.ts patched: DeviceListItem + DevicesListResponse appended"
}

# --- Patch 2: app-sidebar.tsx - add Boxes import + Devices nav entry ---
$sidebar = "app\window\src\components\app-sidebar.tsx"
$scontent = Get-Content $sidebar -Raw

if ($scontent -match '"Devices".*"/devices"') {
    Write-Host "Devices nav entry already in app-sidebar.tsx - skipping patch 2"
} else {
    # 2a: Add Boxes to lucide import
    $oldImport = @'
import {
  LayoutDashboard,
  Bell,
  FileText,
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

    # 2b: Update the nav-items comment to drop "Devices" from omitted list
    $oldComment = @'
// Navigation items shown in the main sidebar group.
// Only routes that are actually wired and gated render here. Obligations
// and Devices were planned for Phase 5 and remain intentionally omitted
// until the corresponding pages exist; showing a link that 404s would be
// worse than not showing it at all. Audit log shipped in Phase 5A.
'@
    $newComment = @'
// Navigation items shown in the main sidebar group.
// Only routes that are actually wired and gated render here. Obligations
// remains intentionally omitted until Phase 5C ships; showing a link
// that 404s would be worse than not showing it at all. Audit log
// shipped in Phase 5A, Devices catalog (read-only) shipped in Phase 5B.
'@
    if ($scontent -notmatch [regex]::Escape($oldComment)) {
        Write-Error "Could not find navItems comment anchor in app-sidebar.tsx"
        exit 1
    }
    $scontent = $scontent -replace [regex]::Escape($oldComment), $newComment

    # 2c: Add Devices entry to navItems
    $oldNav = @'
const navItems = [
  { title: "Dashboard", url: "/", icon: LayoutDashboard },
  { title: "Alerts", url: "/alerts", icon: Bell },
  { title: "Audit log", url: "/audit", icon: FileText },
]
'@
    $newNav = @'
const navItems = [
  { title: "Dashboard", url: "/", icon: LayoutDashboard },
  { title: "Alerts", url: "/alerts", icon: Bell },
  { title: "Devices", url: "/devices", icon: Boxes },
  { title: "Audit log", url: "/audit", icon: FileText },
]
'@
    if ($scontent -notmatch [regex]::Escape($oldNav)) {
        Write-Error "Could not find navItems array anchor in app-sidebar.tsx"
        exit 1
    }
    $scontent = $scontent -replace [regex]::Escape($oldNav), $newNav

    Set-Content -Path $sidebar -Value $scontent -NoNewline
    Write-Host "app-sidebar.tsx patched: Boxes icon + Devices entry added"
}

# --- Patch 3: site-header.tsx - "Devices" page title already present ---
# (Confirmed in earlier grep that pageTitles already has 'devices'.)

# --- Verify ---
Write-Host ""
Write-Host "--- Verify types.ts ---"
Get-Content $typesFile | Select-String -Pattern "DeviceListItem|DevicesListResponse|DeviceClass" | Select-Object LineNumber, Line | Format-Table -AutoSize

Write-Host "--- Verify app-sidebar.tsx ---"
Get-Content $sidebar | Select-String -Pattern "Boxes|/devices|Devices" | Select-Object LineNumber, Line | Format-Table -AutoSize
