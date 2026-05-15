# apply-multi-audience-patch.ps1
# Patches auth.py and ecs-brain-service.tf to accept JWTs from multiple
# Cognito app clients (web + cli).
#
# Industry-standard pattern: PyJWT and most OIDC libraries accept the
# `audience` parameter as either a string or a list. When a list is
# passed, the token's `aud` claim is accepted if it matches ANY entry.
# This lets one service trust JWTs from multiple registered clients
# (browser app, CLI tool, mobile, partner integrations) without losing
# the audience-verification security property.

$ErrorActionPreference = "Stop"

$authPy        = "app\brain\src\auth.py"
$brainTf       = "terraform\environments\dev\ecs-brain-service.tf"

# --- Patch 1: auth.py ---

Write-Host "==> Patching auth.py..."

$authContent = Get-Content $authPy -Raw

# Idempotency check
if ($authContent -match "COGNITO_APP_CLIENT_IDS\s*=") {
    Write-Host "    Already patched - skipping"
} else {
    # Old block (multi-line string)
    $oldDeclare = @'
COGNITO_APP_CLIENT_ID = os.environ.get(
    "COGNITO_APP_CLIENT_ID", "132om57mrn5k7433dcmt53mfof"
)
'@

    # New block - parse comma-separated env var into a list
    $newDeclare = @'
# Audience can be a single client or comma-separated list. PyJWT accepts
# a list for `audience` and validates that the token's `aud` matches any
# entry. The default value covers the web client for backward
# compatibility with deployments that have not set the env var yet.
COGNITO_APP_CLIENT_IDS = [
    s.strip()
    for s in os.environ.get(
        "COGNITO_APP_CLIENT_IDS", "132om57mrn5k7433dcmt53mfof"
    ).split(",")
    if s.strip()
]
'@

    if ($authContent -notmatch [regex]::Escape($oldDeclare)) {
        Write-Error "Could not find COGNITO_APP_CLIENT_ID declaration block in auth.py - has it already been edited?"
        exit 1
    }
    $authContent = $authContent -replace [regex]::Escape($oldDeclare), $newDeclare

    # Now update the jwt.decode call to use the new list
    $oldDecode = "audience=COGNITO_APP_CLIENT_ID,"
    $newDecode = "audience=COGNITO_APP_CLIENT_IDS,"

    if ($authContent -notmatch [regex]::Escape($oldDecode)) {
        Write-Error "Could not find 'audience=COGNITO_APP_CLIENT_ID,' in auth.py"
        exit 1
    }
    $authContent = $authContent -replace [regex]::Escape($oldDecode), $newDecode

    Set-Content -Path $authPy -Value $authContent -NoNewline
    Write-Host "    auth.py patched"
}

# --- Patch 2: ecs-brain-service.tf ---

Write-Host ""
Write-Host "==> Patching ecs-brain-service.tf..."

$tfContent = Get-Content $brainTf -Raw

if ($tfContent -match 'COGNITO_APP_CLIENT_IDS') {
    Write-Host "    Already patched - skipping"
} else {
    # Anchor: the last existing env var entry, before the closing ]
    $oldAnchor = '{ name = "AUDIT_KMS_KEY_ARN", value = aws_kms_key.main.arn }'
    $newAnchor = @'
{ name = "AUDIT_KMS_KEY_ARN", value = aws_kms_key.main.arn },
          { name = "COGNITO_APP_CLIENT_IDS", value = "${aws_cognito_user_pool_client.web.id},${aws_cognito_user_pool_client.cli.id}" }
'@

    if ($tfContent -notmatch [regex]::Escape($oldAnchor)) {
        Write-Error "Could not find AUDIT_KMS_KEY_ARN entry in ecs-brain-service.tf"
        exit 1
    }
    $tfContent = $tfContent -replace [regex]::Escape($oldAnchor), $newAnchor

    Set-Content -Path $brainTf -Value $tfContent -NoNewline
    Write-Host "    ecs-brain-service.tf patched"
}

# --- Verify ---
Write-Host ""
Write-Host "--- Verify auth.py ---"
Get-Content $authPy | Select-String -Pattern "COGNITO_APP_CLIENT|audience=" | Select-Object LineNumber, Line | Format-Table -AutoSize

Write-Host "--- Verify ecs-brain-service.tf ---"
Get-Content $brainTf | Select-String -Pattern "COGNITO_APP_CLIENT|AUDIT_KMS_KEY_ARN" | Select-Object LineNumber, Line | Format-Table -AutoSize

Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. cd terraform\environments\dev"
Write-Host "  2. terraform plan '-target=aws_ecs_task_definition.brain'"
Write-Host "  3. terraform apply '-target=aws_ecs_task_definition.brain'"
Write-Host "  4. cd ..\..\..  (back to repo root)"
Write-Host "  5. Repackage source zip:"
Write-Host "       Remove-Item brain-source-audit-list.zip -Force"
Write-Host "       tar -a -c -f brain-source-audit-list.zip app\brain"
Write-Host "       aws s3 cp brain-source-audit-list.zip s3://regops-sentinel-dev-codebuild-1a8df723/brain-source-audit-list.zip"
Write-Host "  6. Redeploy:"
Write-Host "       powershell -ExecutionPolicy Bypass -File .\deploy-audit-endpoint.ps1"
Write-Host "  7. Retest:"
Write-Host "       powershell -ExecutionPolicy Bypass -File .\get-jwt-and-test-audit.ps1"
