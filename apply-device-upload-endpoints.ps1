# apply-device-upload-endpoints.ps1
#
# Appends POST /devices/upload and GET /devices/upload/{job_id} endpoints
# to app/brain/src/main.py.

$ErrorActionPreference = "Stop"

$mainPy = "app\brain\src\main.py"
$rawBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $mainPy).Path)
$content = [System.Text.Encoding]::UTF8.GetString($rawBytes)
$content = $content -replace "`r`n", "`n"

if ($content -match "POST /devices/upload" -or $content -match "create_upload_job") {
    Write-Host "Device upload endpoints already present in main.py - skipping"
    exit 0
}

# Patch 1: import the new module at the top of main.py alongside the other
# brain-local imports.
$importAnchor = 'from .audit import router as audit_router'
$newImport = @'
from .audit import router as audit_router
from .device_upload import create_upload_job, get_upload_job
'@
if ($content -notmatch [regex]::Escape($importAnchor)) {
    Write-Error "Could not find audit_router import anchor"
    exit 1
}
$content = $content -replace [regex]::Escape($importAnchor), ($newImport -replace "`r`n", "`n")

# Patch 2: append the two new endpoints to the end of the file.
# Hard cap on payload size to avoid memory blowout (1MB = ~10k device rows).
$newEndpoints = @'


# ===== Phase 5B.2: Device CSV upload (async) =====

# Hard cap on CSV payload size in bytes. 1MB is ~10,000 device rows in
# MDALL format, an order of magnitude more than any realistic demo
# upload. Anything bigger gets rejected at the HTTP layer before we
# read it into memory.
DEVICE_UPLOAD_MAX_BYTES = 1024 * 1024


@app.post("/devices/upload", status_code=202)
async def post_devices_upload(
    request: Request,
    user: CurrentUser = Depends(current_user),
):
    """Accept a CSV body, create an upload job, return its job_id.

    Returns 202 Accepted because the work happens asynchronously. The
    caller polls GET /devices/upload/{job_id} for progress.
    """
    body = await request.body()
    if len(body) > DEVICE_UPLOAD_MAX_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"upload exceeds max size of {DEVICE_UPLOAD_MAX_BYTES} bytes",
        )
    if not body:
        raise HTTPException(status_code=400, detail="empty payload")

    try:
        payload_csv = body.decode("utf-8")
    except UnicodeDecodeError:
        raise HTTPException(status_code=400, detail="payload must be UTF-8 CSV")

    filename = request.headers.get("x-upload-filename")

    try:
        job_id = create_upload_job(
            tenant_id=user.tenant_id,
            payload_csv=payload_csv,
            filename=filename,
        )
    except Exception:
        logger.exception("failed to create device upload job")
        raise HTTPException(status_code=500, detail="failed to queue upload")

    return {"job_id": job_id, "status": "queued"}


@app.get("/devices/upload/{job_id}")
def get_devices_upload(
    job_id: str,
    user: CurrentUser = Depends(current_user),
):
    """Return current state of an upload job. Tenant-scoped."""
    job = get_upload_job(tenant_id=user.tenant_id, job_id=job_id)
    if not job:
        # Cross-tenant lookups, malformed UUIDs, and not-found all return
        # 404 to avoid leaking job existence to unauthorised callers.
        raise HTTPException(status_code=404, detail="job not found")
    return job
'@

$content = $content.TrimEnd() + ($newEndpoints -replace "`r`n", "`n") + "`n"

[System.IO.File]::WriteAllBytes(
    (Resolve-Path $mainPy).Path,
    [System.Text.Encoding]::UTF8.GetBytes($content)
)

Write-Host "main.py patched:"
Write-Host "    - import: from .device_upload import create_upload_job, get_upload_job"
Write-Host "    - POST /devices/upload"
Write-Host "    - GET /devices/upload/{job_id}"
