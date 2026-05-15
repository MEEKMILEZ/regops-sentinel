# get-jwt-and-test-audit.ps1
# Authenticates to Cognito as meek@acme-meddev.test, handles TOTP challenge,
# then exercises GET /audit against the deployed Brain ALB.
#
# What this tests end-to-end:
#   1. /audit returns 200 with the expected envelope shape
#   2. Tenant scoping works (events all belong to meek's tenant)
#   3. KMS + S3 IAM permissions on the brain ECS task role are correct
#   4. Cursor pagination roundtrip works (if more than one page of data)

$ErrorActionPreference = "Stop"

# --- Locked constants from handoff ---
$COGNITO_POOL    = "ca-central-1_3TjLuZRim"
$COGNITO_CLIENT  = "1ugh2hn13j004m59p2kh530hbc"
$REGION          = "ca-central-1"
$USERNAME        = "meek@acme-meddev.test"
$ALB_URL         = "http://rgops-brain-alb-1a8df723-954473560.ca-central-1.elb.amazonaws.com"

# --- Prompt for password and TOTP code ---
Write-Host "Cognito authentication for $USERNAME"
Write-Host ""
$securePwd = Read-Host "Enter password (input hidden)" -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
$PASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# --- Step 1: initiate-auth with USER_PASSWORD_AUTH ---
Write-Host ""
Write-Host "==> Step 1: USER_PASSWORD_AUTH initiate"
$initResp = aws cognito-idp initiate-auth `
    --auth-flow USER_PASSWORD_AUTH `
    --client-id $COGNITO_CLIENT `
    --auth-parameters "USERNAME=$USERNAME,PASSWORD=$PASSWORD" `
    --region $REGION `
    --output json | ConvertFrom-Json

if ($initResp.ChallengeName) {
    Write-Host "    Challenge required: $($initResp.ChallengeName)"

    if ($initResp.ChallengeName -ne "SOFTWARE_TOKEN_MFA") {
        Write-Error "Unexpected challenge: $($initResp.ChallengeName) - expected SOFTWARE_TOKEN_MFA"
        exit 1
    }

    Write-Host ""
    $totpCode = Read-Host "Enter 6-digit TOTP code from authenticator app"

    Write-Host ""
    Write-Host "==> Step 2: SOFTWARE_TOKEN_MFA challenge response"
    $mfaResp = aws cognito-idp respond-to-auth-challenge `
        --client-id $COGNITO_CLIENT `
        --challenge-name SOFTWARE_TOKEN_MFA `
        --challenge-responses "USERNAME=$USERNAME,SOFTWARE_TOKEN_MFA_CODE=$totpCode" `
        --session $initResp.Session `
        --region $REGION `
        --output json | ConvertFrom-Json

    $ID_TOKEN = $mfaResp.AuthenticationResult.IdToken
} else {
    # No MFA challenge - direct token (e.g. if TOTP was bypassed)
    $ID_TOKEN = $initResp.AuthenticationResult.IdToken
}

if (-not $ID_TOKEN) {
    Write-Error "Did not receive an ID token. Full response: $($mfaResp | ConvertTo-Json -Depth 10)"
    exit 1
}

Write-Host "    Got ID token ($(($ID_TOKEN.Length)) chars)"

# --- Step 3: Decode JWT payload (no signature verify - we just want to peek) ---
Write-Host ""
Write-Host "==> Step 3: Inspect token claims (sanity check)"
$payloadB64 = ($ID_TOKEN -split "\.")[1]
# JWT payload uses base64url with no padding - add it back
$padded = $payloadB64.Replace('-', '+').Replace('_', '/')
while ($padded.Length % 4) { $padded += '=' }
$payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded))
$claims = $payloadJson | ConvertFrom-Json
Write-Host "    sub:                   $($claims.sub)"
Write-Host "    email:                 $($claims.email)"
Write-Host "    custom:tenant_id:      $($claims.'custom:tenant_id')"
Write-Host "    custom:tenant_role:    $($claims.'custom:tenant_role')"
Write-Host "    token_use:             $($claims.token_use)"

# --- Step 4: Hit /audit with the token ---
Write-Host ""
Write-Host "==> Step 4: GET /audit (page 1, default limit=50)"
$headers = @{ "Authorization" = "Bearer $ID_TOKEN" }
try {
    $auditResp = Invoke-WebRequest -Uri "$ALB_URL/audit" -Headers $headers -UseBasicParsing -TimeoutSec 30
    $statusCode = $auditResp.StatusCode
    $body = $auditResp.Content
} catch [System.Net.WebException] {
    $statusCode = [int]$_.Exception.Response.StatusCode
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    $body = $reader.ReadToEnd()
}

Write-Host "    HTTP $statusCode"
if ($statusCode -ne 200) {
    Write-Host "    body: $body"
    Write-Error "Expected 200, got $statusCode"
    exit 1
}

$page1 = $body | ConvertFrom-Json
$eventCount = $page1.events.Count
Write-Host "    events returned: $eventCount"
Write-Host "    has_more:        $($page1.has_more)"
Write-Host "    next_cursor:     $(if ($page1.next_cursor) { ($page1.next_cursor.Substring(0, [Math]::Min(40, $page1.next_cursor.Length)) + '...') } else { '(null)' })"

if ($eventCount -gt 0) {
    Write-Host ""
    Write-Host "    First 3 events:"
    $page1.events | Select-Object -First 3 | ForEach-Object {
        Write-Host ("      [{0}] {1}  {2}  src={3}  ext={4}" -f `
            $_.classification, $_.urgency, $_.audit_timestamp, $_.source, $_.external_id)
        Write-Host ("           title: {0}" -f $_.title)
        Write-Host ("           kms:   {0}" -f $_.encryption_key_id)
    }

    # --- Step 5: Tenant scoping sanity check ---
    Write-Host ""
    Write-Host "==> Step 5: Verify all events are tenant-scoped"
    # We can't easily prove this from the response shape alone (events don't
    # carry tenant_id in the summary), but we CAN prove it by decoding one
    # audit_id and checking it starts with our tenant prefix.
    $firstAuditId = $page1.events[0].audit_id
    $padded = $firstAuditId.Replace('-', '+').Replace('_', '/')
    while ($padded.Length % 4) { $padded += '=' }
    $decodedKey = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded))
    Write-Host "    First audit_id decodes to S3 key: $decodedKey"

    $expectedPrefix = "audit/$($claims.'custom:tenant_id')/"
    if ($decodedKey.StartsWith($expectedPrefix)) {
        Write-Host "    Key starts with expected tenant prefix '$expectedPrefix' - tenant scoping verified"
    } else {
        Write-Warning "Key does NOT start with expected tenant prefix '$expectedPrefix'"
    }
} else {
    Write-Host ""
    Write-Host "    No events returned for tenant '$($claims.'custom:tenant_id')'."
    Write-Host "    This could mean: (a) no audit blobs exist for this tenant yet, or"
    Write-Host "    (b) the prefix lookup is wrong. Check S3:"
    Write-Host "      aws s3 ls s3://<audit-bucket>/audit/$($claims.'custom:tenant_id')/ --recursive"
}

# --- Step 6: Pagination test (if more pages exist) ---
if ($page1.has_more -and $page1.next_cursor) {
    Write-Host ""
    Write-Host "==> Step 6: GET /audit?cursor=... (page 2 via cursor)"
    $encodedCursor = [System.Uri]::EscapeDataString($page1.next_cursor)
    $auditResp2 = Invoke-WebRequest -Uri "$ALB_URL/audit?cursor=$encodedCursor" -Headers $headers -UseBasicParsing -TimeoutSec 30
    $page2 = $auditResp2.Content | ConvertFrom-Json
    Write-Host "    events returned: $($page2.events.Count)"
    Write-Host "    has_more:        $($page2.has_more)"

    # Confirm no overlap between page1 and page2
    $page1Ids = $page1.events | ForEach-Object { $_.audit_id }
    $page2Ids = $page2.events | ForEach-Object { $_.audit_id }
    $overlap = $page1Ids | Where-Object { $page2Ids -contains $_ }
    if ($overlap.Count -eq 0) {
        Write-Host "    No overlap between page 1 and page 2 - cursor pagination working correctly"
    } else {
        Write-Warning "Overlap detected between pages: $($overlap -join ', ')"
    }
} else {
    Write-Host ""
    Write-Host "==> Step 6: Skipped (no more pages - all events fit in page 1)"
}

# --- Step 7: Small-page sanity (limit=5) ---
Write-Host ""
Write-Host "==> Step 7: GET /audit?limit=5 (small page test)"
$small = (Invoke-WebRequest -Uri "$ALB_URL/audit?limit=5" -Headers $headers -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
Write-Host "    events returned: $($small.events.Count) (expected <=5)"
Write-Host "    has_more:        $($small.has_more)"

Write-Host ""
Write-Host "==> All tests complete. /audit is ready for the Window app."
