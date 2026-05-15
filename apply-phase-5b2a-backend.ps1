# apply-phase-5b2a-backend.ps1
#
# Phase 5B.2-A: device CSV upload backend.
#
# This script wires up:
#   1. db.py update - new device_upload_jobs table
#   2. New device_upload.py module - MDALL CSV parser + async worker
#   3. main.py patch - POST /devices/upload + GET /devices/upload/{job_id}
#   4. Sample MDALL CSV - for testing
#
# Then deploys the brain image and smoke-tests the new endpoints.

$ErrorActionPreference = "Stop"

Write-Host "Phase 5B.2-A: Device CSV upload backend"
Write-Host "========================================"
Write-Host ""

# --- Step 1: Move files into place ---

Write-Host "Step 1: Staging files..."

# db.py replaces existing
Copy-Item -Force "$env:USERPROFILE\Downloads\db.py" "app\brain\src\db.py"
Write-Host "    app/brain/src/db.py        (updated)"

# device_upload.py is new
Copy-Item -Force "$env:USERPROFILE\Downloads\device_upload.py" "app\brain\src\device_upload.py"
Write-Host "    app/brain/src/device_upload.py        (new)"

# Sample CSV goes into a docs folder for reference and testing
$samplesDir = "app\brain\samples"
if (-not (Test-Path $samplesDir)) {
    New-Item -ItemType Directory -Path $samplesDir | Out-Null
}
Copy-Item -Force "$env:USERPROFILE\Downloads\sample-mdall-export.csv" "$samplesDir\sample-mdall-export.csv"
Write-Host "    app/brain/samples/sample-mdall-export.csv        (new)"

Write-Host ""

# --- Step 2: Apply main.py patch ---

Write-Host "Step 2: Patching main.py to register the new endpoints..."
& "$env:USERPROFILE\Downloads\apply-device-upload-endpoints.ps1"

Write-Host ""

# --- Step 3: Deploy brain ---

Write-Host "Step 3: Deploying brain image..."
Write-Host "    (Using the existing deploy-audit-endpoint.ps1 pattern.)"
Write-Host ""
Write-Host "    Run manually:    powershell -ExecutionPolicy Bypass -File .\deploy-audit-endpoint.ps1"
Write-Host ""
Write-Host "    Wait for ECS rollout to complete before smoke-testing."
Write-Host "    (Check 'aws ecs describe-services' deployments array for old task to drain.)"

Write-Host ""
Write-Host "==================================================================="
Write-Host "Phase 5B.2-A files staged. Next steps:"
Write-Host ""
Write-Host "  1. Deploy:     powershell -ExecutionPolicy Bypass -File .\deploy-audit-endpoint.ps1"
Write-Host ""
Write-Host "  2. Wait for ECS rollout (watch task definition revision bump and"
Write-Host "     for the new task to be RUNNING + old task DRAINED)."
Write-Host ""
Write-Host "  3. Smoke test - upload the sample CSV (requires fresh JWT):"
Write-Host ""
Write-Host "       `$TOKEN = <your fresh access token from get-jwt.ps1>"
Write-Host "       `$BRAIN = 'http://rgops-brain-alb-1a8df723-954473560.ca-central-1.elb.amazonaws.com'"
Write-Host "       `$CSV = Get-Content app\brain\samples\sample-mdall-export.csv -Raw"
Write-Host ""
Write-Host "       # POST CSV - expect 202 Accepted with {job_id, status}"
Write-Host "       `$resp = Invoke-RestMethod -Uri `"`$BRAIN/devices/upload`" -Method POST ``"
Write-Host "          -Headers @{ Authorization = `"Bearer `$TOKEN`"; 'x-upload-filename' = 'sample-mdall-export.csv' } ``"
Write-Host "          -ContentType 'text/csv' -Body `$CSV"
Write-Host "       `$JOB_ID = `$resp.job_id"
Write-Host ""
Write-Host "       # Poll status - expect to see status flip queued -> processing -> complete"
Write-Host "       for (`$i = 0; `$i -lt 10; `$i++) {"
Write-Host "          `$status = Invoke-RestMethod -Uri `"`$BRAIN/devices/upload/`$JOB_ID`" ``"
Write-Host "             -Headers @{ Authorization = `"Bearer `$TOKEN`" }"
Write-Host "          `$status | ConvertTo-Json -Depth 5"
Write-Host "          if (`$status.status -in 'complete','failed') { break }"
Write-Host "          Start-Sleep -Seconds 2"
Write-Host "       }"
Write-Host ""
Write-Host "  4. Verify the devices appeared in the /devices page (refresh browser)."
Write-Host "==================================================================="
