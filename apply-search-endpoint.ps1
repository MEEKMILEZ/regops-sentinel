# apply-search-endpoint.ps1
# Appends GET /search to main.py - cross-table full-text search using
# Postgres tsvector ranked union across alerts/devices/obligations.

$ErrorActionPreference = "Stop"

$mainPy = "app\brain\src\main.py"
$content = Get-Content $mainPy -Raw

if ($content -match "def search_endpoint\(") {
    Write-Host "Search endpoint already in main.py - skipping"
    exit 0
}

$endpoint = @'


@app.get("/search")
def search_endpoint(
    q: str,
    user: CurrentUser = Depends(current_user),
    limit: int = 10,
):
    """Cross-table full-text search across alerts, devices, obligations.

    Uses Postgres tsvector + GIN index for indexed lookup. Each table
    contributes rows with a normalised shape (kind/id/title/subtitle/url/
    rank) so the UI can render a flat dropdown. ts_rank is used to sort
    results across tables by relevance, not by recency.

    Tenant scoping is enforced on every UNION arm. The q parameter is
    safely converted to a tsquery via plainto_tsquery, so user input
    cannot inject tsquery operators.
    """
    q_clean = (q or "").strip()
    if not q_clean:
        return {"query": "", "results": [], "count": 0}
    try:
        with get_connection() as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    """
                    SELECT * FROM (
                        SELECT
                            'alert'::text                       AS kind,
                            alert_id::bigint                    AS id,
                            title                               AS title,
                            COALESCE(summary, source)           AS subtitle,
                            ('/alerts/' || alert_id)::text      AS url,
                            urgency                             AS badge,
                            ts_rank(search_vector, plainto_tsquery('english', %s)) AS rank
                        FROM alerts
                        WHERE tenant_id = %s
                          AND search_vector @@ plainto_tsquery('english', %s)

                        UNION ALL

                        SELECT
                            'device'::text                      AS kind,
                            device_id::bigint                   AS id,
                            brand_name                          AS title,
                            manufacturer                        AS subtitle,
                            '/devices'::text                    AS url,
                            device_class                        AS badge,
                            ts_rank(search_vector, plainto_tsquery('english', %s)) AS rank
                        FROM devices
                        WHERE tenant_id = %s
                          AND search_vector @@ plainto_tsquery('english', %s)

                        UNION ALL

                        SELECT
                            'obligation'::text                  AS kind,
                            obligation_id::bigint               AS id,
                            title                               AS title,
                            COALESCE(obligation_type, '')       AS subtitle,
                            '/obligations'::text                AS url,
                            status                              AS badge,
                            ts_rank(search_vector, plainto_tsquery('english', %s)) AS rank
                        FROM obligations
                        WHERE tenant_id = %s
                          AND search_vector @@ plainto_tsquery('english', %s)
                    ) results
                    ORDER BY rank DESC, title ASC
                    LIMIT %s
                    """,
                    (
                        q_clean, user.tenant_id, q_clean,
                        q_clean, user.tenant_id, q_clean,
                        q_clean, user.tenant_id, q_clean,
                        limit,
                    ),
                )
                rows = cur.fetchall()
        # ts_rank returns a float; ensure JSON-safe.
        for r in rows:
            r["rank"] = float(r["rank"]) if r.get("rank") is not None else 0.0
        return {
            "query": q_clean,
            "count": len(rows),
            "results": rows,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "search failed for tenant %s, query %r",
            user.tenant_id,
            q_clean,
        )
        raise HTTPException(status_code=500, detail=str(e))
'@

Add-Content -Path $mainPy -Value $endpoint
Write-Host "Search endpoint appended to main.py"

Write-Host ""
Write-Host "--- Verify ---"
Get-Content $mainPy | Select-String -Pattern "^def " | Select-Object LineNumber, Line | Format-Table -AutoSize
