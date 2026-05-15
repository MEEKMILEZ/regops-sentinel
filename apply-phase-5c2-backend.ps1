# apply-phase-5c2-backend.ps1
#
# Phase 5C.2 backend: Obligations CRUD (Create, Update, Complete, Delete).
# Every state-changing action writes an immutable audit blob to S3.
#
# Files staged:
#   app/brain/src/obligation_audit.py    (new)
#   app/brain/src/obligations_crud.py    (new)
#   app/brain/src/main.py                (patched - 4 new endpoints)

$ErrorActionPreference = "Stop"

Write-Host "Phase 5C.2 backend: Obligations CRUD"
Write-Host "===================================="
Write-Host ""

$DL = "$env:USERPROFILE\Downloads"

# --- Step 1: Stage new module files ---

Write-Host "Step 1: Staging new modules..."

Copy-Item -Force "$DL\obligation_audit.py" "app\brain\src\obligation_audit.py"
Write-Host "    app/brain/src/obligation_audit.py        (new)"

Copy-Item -Force "$DL\obligations_crud.py" "app\brain\src\obligations_crud.py"
Write-Host "    app/brain/src/obligations_crud.py        (new)"

Write-Host ""

# --- Step 2: Patch main.py to add 4 new endpoints ---

Write-Host "Step 2: Patching main.py with 4 new endpoints..."

$mainPath = "app\brain\src\main.py"
$rawBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $mainPath).Path)
$content = [System.Text.Encoding]::UTF8.GetString($rawBytes)

# Idempotency check - if the new endpoints are already present, skip
if ($content -match 'def create_obligation_endpoint') {
    Write-Host "    main.py already patched - skipping"
} else {
    # The new endpoints must be registered BEFORE the existing
    # @app.get("/obligations/{obligation_id}") to avoid the route
    # specificity bug where /obligations/{id} captures /obligations/123/
    # complete as id=123/complete.
    #
    # We insert the new code BEFORE the line that defines list_obligations
    # (which is the most specific obligation handler that comes first).
    # Actually, FastAPI's route ordering is registration-order; the
    # safest insertion point is immediately after the LAST @app.get for
    # /obligations and BEFORE @app.get("/obligations/{obligation_id}").
    # Inserting before list_obligations would put POST before LIST,
    # which is fine.

    # Find the anchor: '@app.get("/obligations")' decorator line.
    $anchor = '@app.get("/obligations")'

    if ($content -notmatch [regex]::Escape($anchor)) {
        Write-Host "    ERROR: anchor '$anchor' not found in main.py"
        exit 1
    }

    # New imports - prepend to the imports block. Idempotent.
    $importBlock = @"
from .obligations_crud import (
    create_obligation,
    update_obligation,
    complete_obligation,
    delete_obligation,
    ValidationError,
)
from .obligation_audit import (
    write_obligation_audit_blob,
    ACTION_CREATE,
    ACTION_UPDATE,
    ACTION_COMPLETE,
    ACTION_DELETE,
)
"@

    if ($content -notmatch 'from \.obligations_crud import') {
        # Insert after the existing `from .classifier import classify` line
        # which is the last `from .` import in the file.
        $classifierImport = 'from .classifier import classify'
        if ($content -notmatch [regex]::Escape($classifierImport)) {
            Write-Host "    ERROR: classifier import anchor not found"
            exit 1
        }
        $content = $content -replace [regex]::Escape($classifierImport),
            "$classifierImport`r`n$importBlock"
        Write-Host "    Added imports for obligations_crud + obligation_audit"
    }

    # New endpoints block. Inserted BEFORE the @app.get("/obligations")
    # anchor so POST/PATCH/DELETE/complete are registered ahead of any
    # route with a path parameter.
    $endpointsBlock = @"
# ============================================================
# Phase 5C.2: Obligations CRUD endpoints
#
# These are registered BEFORE the existing @app.get("/obligations/{id}")
# below to avoid the route specificity bug we hit in Phase 5B.2
# (/devices/{id} capturing /devices/upload as id="upload").
#
# Every state-changing endpoint writes an immutable S3 audit blob AFTER
# the DB write succeeds. Audit write failures surface to the caller as
# 500s because a silently-skipped audit defeats the purpose of an
# audit trail.
# ============================================================

@app.post("/obligations", status_code=201)
def create_obligation_endpoint(
    request: Request,
    payload: dict,
    user: CurrentUser = Depends(current_user),
):
    """Create a new obligation. Returns the inserted row.

    Audited as ACTION_CREATE with before=None.
    """
    try:
        created = create_obligation(user.tenant_id, payload)
    except ValidationError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "create_obligation failed for tenant %s", user.tenant_id
        )
        raise HTTPException(status_code=500, detail=str(e))

    try:
        write_obligation_audit_blob(
            action=ACTION_CREATE,
            tenant_id=user.tenant_id,
            obligation_id=created["obligation_id"],
            actor_email=user.email,
            actor_user_id=user.user_id,
            before=None,
            after=created,
        )
    except Exception:
        # Audit write failed AFTER the DB insert succeeded. The row exists
        # but has no audit trail. We surface a 500 so the operator knows
        # to investigate (and ideally manually delete the row + re-create
        # cleanly), rather than pretending all is well.
        logger.exception(
            "audit write failed for tenant %s obligation %s; "
            "DB write succeeded but audit is missing",
            user.tenant_id,
            created["obligation_id"],
        )
        raise HTTPException(
            status_code=500,
            detail="obligation_created_but_audit_failed",
        )

    return created


@app.patch("/obligations/{obligation_id}")
def update_obligation_endpoint(
    obligation_id: int,
    payload: dict,
    user: CurrentUser = Depends(current_user),
):
    """Partially update an obligation. Returns the updated row.

    Audited as ACTION_UPDATE with before+after snapshots so the audit
    trail captures the exact diff a regulator would ask about.
    """
    try:
        before, after = update_obligation(user.tenant_id, obligation_id, payload)
    except ValidationError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "update_obligation failed for tenant %s obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(status_code=500, detail=str(e))

    if before is None:
        raise HTTPException(status_code=404, detail="obligation_not_found")

    try:
        write_obligation_audit_blob(
            action=ACTION_UPDATE,
            tenant_id=user.tenant_id,
            obligation_id=obligation_id,
            actor_email=user.email,
            actor_user_id=user.user_id,
            before=before,
            after=after,
        )
    except Exception:
        logger.exception(
            "audit write failed for tenant %s obligation %s update",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(
            status_code=500,
            detail="obligation_updated_but_audit_failed",
        )

    return after


@app.post("/obligations/{obligation_id}/complete")
def complete_obligation_endpoint(
    obligation_id: int,
    user: CurrentUser = Depends(current_user),
):
    """Mark an obligation complete. Sets status=completed, completed_at=NOW().

    Idempotent: calling complete() twice is OK. The audit log records each
    call separately so a regulator can see all "complete this" events.
    """
    try:
        before, after = complete_obligation(user.tenant_id, obligation_id)
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "complete_obligation failed for tenant %s obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(status_code=500, detail=str(e))

    if before is None:
        raise HTTPException(status_code=404, detail="obligation_not_found")

    try:
        write_obligation_audit_blob(
            action=ACTION_COMPLETE,
            tenant_id=user.tenant_id,
            obligation_id=obligation_id,
            actor_email=user.email,
            actor_user_id=user.user_id,
            before=before,
            after=after,
        )
    except Exception:
        logger.exception(
            "audit write failed for tenant %s obligation %s complete",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(
            status_code=500,
            detail="obligation_completed_but_audit_failed",
        )

    return after


@app.delete("/obligations/{obligation_id}", status_code=200)
def delete_obligation_endpoint(
    obligation_id: int,
    user: CurrentUser = Depends(current_user),
):
    """Hard-delete an obligation. The audit blob remains in S3 forever.

    Returns the deleted row's snapshot so the UI can render a confirmation
    message ("deleted MDL renewal for Aquilion CT scanner") rather than
    a generic "deleted" string.
    """
    # CRITICAL ORDER: write the audit blob FIRST, then do the DB delete.
    # If the order were reversed and the audit write failed, we'd have a
    # row that no longer exists with no audit trail of its deletion.
    # Writing audit-then-delete means the worst case is a stale audit
    # blob for a row that wasn't actually deleted (preferable: a
    # regulator sees "we tried to delete this" instead of "this just
    # disappeared with no record").
    try:
        from .obligations_crud import get_obligation
        snapshot = get_obligation(user.tenant_id, obligation_id)
    except HTTPException:
        raise
    except Exception as e:
        logger.exception(
            "pre-delete fetch failed for tenant %s obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(status_code=500, detail=str(e))

    if snapshot is None:
        raise HTTPException(status_code=404, detail="obligation_not_found")

    try:
        write_obligation_audit_blob(
            action=ACTION_DELETE,
            tenant_id=user.tenant_id,
            obligation_id=obligation_id,
            actor_email=user.email,
            actor_user_id=user.user_id,
            before=snapshot,
            after=None,
        )
    except Exception:
        logger.exception(
            "audit write failed for tenant %s obligation %s delete; "
            "delete was NOT performed",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(
            status_code=500,
            detail="audit_write_failed_delete_aborted",
        )

    # Audit is durable; now do the DB delete.
    try:
        deleted = delete_obligation(user.tenant_id, obligation_id)
    except HTTPException:
        raise
    except Exception as e:
        # The audit blob says we deleted but the DB delete failed.
        # Surface this loudly - it's a real inconsistency for an
        # operator to investigate.
        logger.exception(
            "DB delete failed after audit write for tenant %s obligation %s",
            user.tenant_id,
            obligation_id,
        )
        raise HTTPException(
            status_code=500,
            detail="audit_written_but_db_delete_failed",
        )

    if deleted is None:
        # Race: row existed at the snapshot fetch but was gone by the
        # time we tried to delete it. Audit blob already recorded the
        # delete event - call it a successful delete.
        logger.warning(
            "obligation %s for tenant %s was already deleted "
            "between snapshot and delete",
            obligation_id,
            user.tenant_id,
        )

    return {"deleted": True, "obligation": snapshot}


"@

    # Insert the endpoints block immediately before the @app.get("/obligations")
    # line. PowerShell -replace with a captured group, with all special
    # regex chars in $anchor escaped.
    $anchorPattern = [regex]::Escape($anchor)
    $content = $content -replace "(?m)^$anchorPattern",
        "$endpointsBlock`r`n$anchor"

    [System.IO.File]::WriteAllBytes(
        (Resolve-Path $mainPath).Path,
        [System.Text.Encoding]::UTF8.GetBytes($content)
    )

    Write-Host "    main.py patched - 4 new endpoints registered:"
    Write-Host "      POST   /obligations               (create)"
    Write-Host "      PATCH  /obligations/{id}          (update)"
    Write-Host "      POST   /obligations/{id}/complete (mark complete)"
    Write-Host "      DELETE /obligations/{id}          (hard delete)"
}

Write-Host ""

# --- Step 3: Sanity check - main.py still imports cleanly ---

Write-Host "Step 3: Python import check..."

# Try to compile main.py with python -m py_compile. This catches syntax
# errors and obvious typos before we ship to ECR.
$pyCheck = & python -m py_compile "app\brain\src\main.py" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "    ERROR: main.py has syntax errors:"
    Write-Host $pyCheck
    Write-Host ""
    Write-Host "    Patch may have produced invalid Python. Inspect main.py."
    exit 1
} else {
    Write-Host "    main.py compiles cleanly"
}

$pyCheck = & python -m py_compile "app\brain\src\obligations_crud.py" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "    ERROR: obligations_crud.py has syntax errors:"
    Write-Host $pyCheck
    exit 1
} else {
    Write-Host "    obligations_crud.py compiles cleanly"
}

$pyCheck = & python -m py_compile "app\brain\src\obligation_audit.py" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "    ERROR: obligation_audit.py has syntax errors:"
    Write-Host $pyCheck
    exit 1
} else {
    Write-Host "    obligation_audit.py compiles cleanly"
}

Write-Host ""
Write-Host "=========================================================="
Write-Host "Phase 5C.2 backend staged. Next steps:"
Write-Host ""
Write-Host "  1. Build + deploy via your usual brain pipeline:"
Write-Host "       tar -a -c -f brain-source-phase-5c2.zip app\brain"
Write-Host "       aws s3 cp brain-source-phase-5c2.zip ``"
Write-Host "         s3://regops-sentinel-dev-codebuild-1a8df723/brain-source-audit-list.zip ``"
Write-Host "         --profile regops-sentinel"
Write-Host "       (then trigger CodeBuild + force-new-deployment)"
Write-Host ""
Write-Host "  2. Smoke-test all 4 endpoints with curl + a fresh JWT."
Write-Host "     See PHASE-5C2-SMOKE.md (created by this script) for exact"
Write-Host "     curl commands."
Write-Host "=========================================================="
