# apply-obligations-endpoints.ps1
# Appends GET /obligations and GET /obligations/{obligation_id}
# endpoints to main.py. Same pattern as /alerts, /audit, /devices.

$ErrorActionPreference = "Stop"

$mainPy = "app\brain\src\main.py"
$content = Get-Content $mainPy -Raw

if ($content -match "def list_obligations\(") {
    Write-Host "Obligations endpoints already in main.py - skipping"
    exit 0
}

$endpoints = @'


@app.get("/obligations")
def list_obligations(
    user: CurrentUser = Depends(current_user),
    limit: int = 100,
):
    """List regulatory obligations for the caller's tenant.

    tenant_id comes from the verified ID token's custom:tenant_id claim.
    Ordered by due_at ASC NULLS LAST so overdue items surface first,
    then due_soon, then upcoming. Status-based ordering follows so a
    completed task with an old due_at doesn't bubble to the top.
    """
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT
                        o.obligation_id, o.tenant_id, o.device_id,
                        o.title, o.description, o.obligation_type,
                        o.frequency, o.status, o.regulatory_body,
                        o.due_at, o.severity_if_missed,
                        o.responsible_party, o.related_alert_id,
                        o.notes, o.created_at, o.updated_at,
                        o.completed_at,
                        d.brand_name AS device_brand_name,
                        d.di AS device_di
                    FROM obligations o
                    LEFT JOIN devices d ON d.device_id = o.device_id
                    WHERE o.tenant_id = %s
                    ORDER BY
                        CASE o.status
                            WHEN 'overdue' THEN 1
                            WHEN 'due_soon' THEN 2
                            WHEN 'upcoming' THEN 3
                            WHEN 'in_progress' THEN 4
                            WHEN 'completed' THEN 5
                            ELSE 6
                        END ASC,
                        o.due_at ASC NULLS LAST
                    LIMIT %s
                    """,
                    (user.tenant_id, limit),
                )
                rows = cur.fetchall()
        return {
            "tenant_id": user.tenant_id,
            "count": len(rows),
            "obligations": rows,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "list_obligations failed for tenant %s", user.tenant_id
        )
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/obligations/{obligation_id}")
def get_obligation(
    obligation_id: int,
    user: CurrentUser = Depends(current_user),
):
    """Fetch a single obligation by id, scoped to the caller's tenant.

    Cross-tenant lookups return 404, not 403 - same 'unguessable
    response' pattern as /alerts/{alert_id} and /devices/{device_id}.
    """
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT
                        o.*,
                        d.brand_name AS device_brand_name,
                        d.di AS device_di
                    FROM obligations o
                    LEFT JOIN devices d ON d.device_id = o.device_id
                    WHERE o.obligation_id = %s AND o.tenant_id = %s
                    LIMIT 1
                    """,
                    (obligation_id, user.tenant_id),
                )
                row = cur.fetchone()
        if row is None:
            raise HTTPException(
                status_code=404, detail="obligation_not_found"
            )
        return row
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "get_obligation failed for tenant %s, obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(status_code=500, detail=str(e))
'@

Add-Content -Path $mainPy -Value $endpoints
Write-Host "Obligations endpoints appended to main.py"

Write-Host ""
Write-Host "--- Verify ---"
Get-Content $mainPy | Select-String -Pattern "^def " | Select-Object LineNumber, Line | Format-Table -AutoSize
Write-Host ("Line count: " + (Get-Content $mainPy).Count)
