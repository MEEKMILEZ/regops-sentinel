# apply-devices-endpoints.ps1
# Appends GET /devices and GET /devices/{device_id} endpoints to main.py.
# Same pattern as /alerts and /audit: sync def, current_user dep,
# dict_row cursor, defensive try/except, tenant-scoped SQL.

$ErrorActionPreference = "Stop"

$mainPy = "app\brain\src\main.py"
$content = Get-Content $mainPy -Raw

if ($content -match "def list_devices\(") {
    Write-Host "Devices endpoints already in main.py - skipping"
    exit 0
}

# Append at end of file. Same pattern as the audit endpoint append.
$endpoints = @'


@app.get("/devices")
def list_devices(
    user: CurrentUser = Depends(current_user),
    limit: int = 100,
):
    """List devices in the caller's tenant catalog.

    tenant_id comes from the verified ID token's custom:tenant_id claim.
    A user holding a token for tenant A cannot see tenant B's devices
    even by passing a different tenant_id - there is no such query
    parameter and the WHERE clause is built from the JWT, not request
    input.
    """
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT
                        device_id, tenant_id, di, brand_name, model_number,
                        manufacturer, mdl_number, device_class, status,
                        clearance_type, product_categories, notes,
                        created_at, updated_at
                    FROM devices
                    WHERE tenant_id = %s
                    ORDER BY device_class ASC, brand_name ASC
                    LIMIT %s
                    """,
                    (user.tenant_id, limit),
                )
                rows = cur.fetchall()
        return {
            "tenant_id": user.tenant_id,
            "count": len(rows),
            "devices": rows,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("list_devices failed for tenant %s", user.tenant_id)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/devices/{device_id}")
def get_device(
    device_id: int,
    user: CurrentUser = Depends(current_user),
):
    """Fetch a single device by id, scoped to the caller's tenant.

    A cross-tenant lookup (user from tenant A asking for tenant B's
    device) returns 404, not 403 - we do not even confirm the device
    exists for another tenant. Same 'unguessable response' pattern as
    /alerts/{alert_id}.
    """
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT *
                    FROM devices
                    WHERE device_id = %s AND tenant_id = %s
                    LIMIT 1
                    """,
                    (device_id, user.tenant_id),
                )
                row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="device_not_found")
        return row
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "get_device failed for tenant %s, device %s",
            user.tenant_id,
            device_id,
        )
        raise HTTPException(status_code=500, detail=str(e))
'@

Add-Content -Path $mainPy -Value $endpoints
Write-Host "Devices endpoints appended to main.py"

Write-Host ""
Write-Host "--- Verify ---"
Get-Content $mainPy | Select-String -Pattern "^def " | Select-Object LineNumber, Line | Format-Table -AutoSize
Write-Host ("Line count: " + (Get-Content $mainPy).Count)
