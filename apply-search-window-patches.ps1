# apply-search-window-patches.ps1
# Two changes:
#   1. types.ts: append SearchResultItem + SearchResponse interfaces
#   2. site-header.tsx: re-wire the search bar using the new SearchBar
#      component (replacing the "stub hidden" comment from Phase 5C)

$ErrorActionPreference = "Stop"

# --- Patch 1: types.ts append ---
$typesFile = "app\window\src\lib\types.ts"
$tcontent = Get-Content $typesFile -Raw

if ($tcontent -match "SearchResultItem") {
    Write-Host "Search types already in types.ts - skipping patch 1"
} else {
    $searchTypes = @'


// --- Cross-table search types -------------------------------------------
//
// The Brain's /search endpoint returns a flat list of results across
// alerts, devices, and obligations, ranked by ts_rank score. Each item
// carries its `kind` so the UI can render the right icon/label and
// follow the right route on click.

export type SearchKind = "alert" | "device" | "obligation"

export interface SearchResultItem {
  kind: SearchKind | string
  id: number
  title: string
  subtitle: string | null
  url: string
  badge: string | null
  /** ts_rank score from Postgres. Higher = more relevant. */
  rank: number
}

export interface SearchResponse {
  query: string
  count: number
  results: SearchResultItem[]
}
'@

    $tcontent = $tcontent.TrimEnd() + $searchTypes + "`r`n"
    Set-Content -Path $typesFile -Value $tcontent -NoNewline
    Write-Host "types.ts patched: SearchResultItem + SearchResponse appended"
}

# --- Patch 2: site-header.tsx - replace 'stub hidden' comment with the real SearchBar ---
$header = "app\window\src\components\site-header.tsx"
$hcontent = Get-Content $header -Raw

if ($hcontent -match "import \{ SearchBar \}") {
    Write-Host "SearchBar already wired into site-header.tsx - skipping patch 2"
} else {
    # 2a: replace the placeholder comment with the SearchBar usage
    $oldPlaceholder = @'
      {/* Stub search bar hidden until full-text search ships (see backlog).
          Showing a non-functional search box is worse than not showing one. */}
'@
    $newPlaceholder = @'
      <SearchBar />
'@
    if ($hcontent -notmatch [regex]::Escape($oldPlaceholder)) {
        Write-Error "Could not find stub-search-bar comment anchor in site-header.tsx"
        exit 1
    }
    $hcontent = $hcontent -replace [regex]::Escape($oldPlaceholder), $newPlaceholder

    # 2b: add the SearchBar import alongside the existing Separator import
    $oldImports = 'import { Separator } from "@/components/ui/separator"'
    $newImports = @'
import { Separator } from "@/components/ui/separator"

import { SearchBar } from "@/components/search/search-bar"
'@
    if ($hcontent -notmatch [regex]::Escape($oldImports)) {
        Write-Error "Could not find Separator import anchor in site-header.tsx"
        exit 1
    }
    $hcontent = $hcontent -replace [regex]::Escape($oldImports), $newImports

    Set-Content -Path $header -Value $hcontent -NoNewline
    Write-Host "site-header.tsx patched: SearchBar wired in"
}

# --- Verify ---
Write-Host ""
Write-Host "--- Verify types.ts ---"
Get-Content $typesFile | Select-String -Pattern "SearchResultItem|SearchResponse|SearchKind" | Select-Object LineNumber, Line | Format-Table -AutoSize

Write-Host "--- Verify site-header.tsx ---"
Get-Content $header | Select-String -Pattern "SearchBar" | Select-Object LineNumber, Line | Format-Table -AutoSize
