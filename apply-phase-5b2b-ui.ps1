# apply-phase-5b2b-ui.ps1
#
# Phase 5B.2-B: device CSV upload UI.
#
# Stages new files and applies one small text patch to devices-table.tsx
# to update the empty-state message.

$ErrorActionPreference = "Stop"

Write-Host "Phase 5B.2-B: Device CSV upload UI"
Write-Host "==================================="
Write-Host ""

$DL = "$env:USERPROFILE\Downloads"

# --- Step 1: Stage new files ---

Write-Host "Step 1: Staging files..."

# types.ts - replaces existing with new DeviceUpload* types added
Copy-Item -Force "$DL\types.ts" "app\window\src\lib\types.ts"
Write-Host "    app/window/src/lib/types.ts        (updated - added DeviceUpload* types)"

# upload-flow.tsx - new client component
$dest = "app\window\src\components\devices\upload-flow.tsx"
Copy-Item -Force "$DL\upload-flow.tsx" $dest
Write-Host "    $dest        (new)"

# BFF routes
$apiDir = "app\window\src\app\api\devices\upload"
if (-not (Test-Path $apiDir)) {
    New-Item -ItemType Directory -Path $apiDir -Force | Out-Null
}
Copy-Item -Force "$DL\devices-upload-route.ts" "$apiDir\route.ts"
Write-Host "    $apiDir\route.ts        (new - POST proxy)"

$jobDir = "$apiDir\[job_id]"
if (-not (Test-Path $jobDir)) {
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
}
Copy-Item -Force "$DL\devices-upload-status-route.ts" "$jobDir\route.ts"
Write-Host "    $jobDir\route.ts        (new - GET status proxy)"

# devices/page.tsx - replaces existing with upload button wired in
Copy-Item -Force "$DL\devices-page-with-upload.tsx" "app\window\src\app\(app)\devices\page.tsx"
Write-Host "    app/window/src/app/(app)/devices/page.tsx        (updated - upload button added)"

Write-Host ""

# --- Step 2: Update devices-table.tsx empty-state message ---

Write-Host "Step 2: Patching devices-table.tsx empty-state message..."

$tablePath = "app\window\src\components\devices\devices-table.tsx"
$rawBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $tablePath).Path)
$content = [System.Text.Encoding]::UTF8.GetString($rawBytes)

$oldMsg = 'No devices in catalog yet. Phase 5B.2 will add CSV upload.'
$newMsg = 'No devices in catalog yet. Use the Upload CSV button to import a Health Canada MDALL export.'

if ($content -match [regex]::Escape($newMsg)) {
    Write-Host "    Empty-state message already updated - skipping"
} elseif ($content -notmatch [regex]::Escape($oldMsg)) {
    Write-Host "    WARN: could not find empty-state message anchor; leaving devices-table.tsx unchanged"
} else {
    $content = $content -replace [regex]::Escape($oldMsg), $newMsg
    [System.IO.File]::WriteAllBytes(
        (Resolve-Path $tablePath).Path,
        [System.Text.Encoding]::UTF8.GetBytes($content)
    )
    Write-Host "    Empty-state message updated"
}

Write-Host ""

# --- Step 3: Verify shadcn Dialog component exists ---

Write-Host "Step 3: Verifying shadcn Dialog component is available..."
$dialogPath = "app\window\src\components\ui\dialog.tsx"
if (Test-Path $dialogPath) {
    Write-Host "    Dialog component present"
} else {
    Write-Host ""
    Write-Host "    !!! Dialog component NOT FOUND at $dialogPath"
    Write-Host "    Install with: cmd /c `"npx shadcn@latest add dialog`""
    Write-Host "    (must be run from the app/window directory)"
    Write-Host ""
    Write-Host "    Without this component, the build will fail."
}

Write-Host ""
Write-Host "==================================================================="
Write-Host "Phase 5B.2-B files staged. Next steps:"
Write-Host ""
Write-Host "  1. If shadcn Dialog is missing, install it:"
Write-Host "       cd app\window"
Write-Host "       cmd /c `"npx shadcn@latest add dialog`""
Write-Host "       cd ..\.."
Write-Host ""
Write-Host "  2. Local build to catch any TS/lint issues:"
Write-Host "       cd app\window"
Write-Host "       cmd /c `"npm run build`""
Write-Host "       cd ..\.."
Write-Host ""
Write-Host "  3. If build passes, the dev deploy (Window is deployed how you"
Write-Host "     normally deploy it - Amplify Hosting / Vercel / etc.). The"
Write-Host "     BFF changes only take effect once the new build is live."
Write-Host ""
Write-Host "  4. Test in browser:"
Write-Host "     - Sign in at /devices"
Write-Host "     - Click Upload CSV"
Write-Host "     - Pick app/brain/samples/sample-mdall-export.csv"
Write-Host "     - Confirm preview shows 15 rows"
Write-Host "     - Click Confirm; watch progress modal"
Write-Host "     - Verify Complete view shows 15 inserted / 0 updated / 0 errors"
Write-Host "       (or 0 inserted / 15 updated if you already ran the smoke test)"
Write-Host "     - Verify the table refreshes with the uploaded devices"
Write-Host ""
Write-Host "  5. Tab-close resume test:"
Write-Host "     - Start an upload"
Write-Host "     - While 'Processing...' is showing, refresh the page"
Write-Host "     - The progress modal should reappear (recovered from localStorage)"
Write-Host "==================================================================="
