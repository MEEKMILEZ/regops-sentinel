# apply-phase-5d-audit-hardening-v3.ps1
#
# v3 fixes the v2 anchor mismatch by normalising line endings to LF
# at the very top before doing any patches, so all string searches
# work against a consistent LF representation.

$ErrorActionPreference = "Stop"

$tfFile = "terraform\environments\dev\s3-audit.tf"

# --- Step 1: Patch s3-audit.tf ---

# Read raw bytes, decode as UTF-8, normalise CRLF -> LF.
$rawBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $tfFile).Path)
$content = [System.Text.Encoding]::UTF8.GetString($rawBytes)
$content = $content -replace "`r`n", "`n"

if ($content -match "aws_s3_bucket_object_lock_configuration") {
    Write-Host "Object Lock config already in s3-audit.tf - skipping patch"
} else {
    # Find the aws_s3_bucket.audit block. Match opening to the matching
    # closing brace (the resource block ends at the first standalone "}").
    # In our specific case, the block is well-formed and ends with "}\n"
    # after the inner "tags" block closes.

    $blockOpen = 'resource "aws_s3_bucket" "audit" {'
    $openIdx = $content.IndexOf($blockOpen)
    if ($openIdx -lt 0) {
        Write-Error "Could not find resource block opening anchor"
        exit 1
    }

    # The block has exactly one nested brace pair (the tags map). Walk
    # the string character by character tracking brace depth so we find
    # the correct closing "}".
    $depth = 0
    $closeIdx = -1
    for ($i = $openIdx; $i -lt $content.Length; $i++) {
        $c = $content[$i]
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) {
                $closeIdx = $i
                break
            }
        }
    }
    if ($closeIdx -lt 0) {
        Write-Error "Could not find matching closing brace for the bucket resource block"
        exit 1
    }

    # The entire original resource block, from "resource" to and
    # including the matching "}".
    $originalBlock = $content.Substring($openIdx, $closeIdx - $openIdx + 1)

    # Sanity-check the block has force_destroy = true
    if ($originalBlock -notmatch "force_destroy\s*=\s*true") {
        Write-Error "Resource block does not contain 'force_destroy = true'"
        Write-Host "Block contents:"
        Write-Host $originalBlock
        exit 1
    }

    # Build the new block - same structure but force_destroy = false,
    # commented, and a new lifecycle block added before the closing brace.
    $newBlock = @'
resource "aws_s3_bucket" "audit" {
  bucket        = "${local.name_prefix}-audit-${local.full_suffix}"
  # Phase 5D: flipped from true. The audit log is the regulatory record
  # of record; nuking it should never be a single-command operation.
  force_destroy = false

  tags = {
    Name = "${local.name_prefix}-audit-${local.full_suffix}"
    Tier = "audit"
  }

  # Object Lock is enabled out-of-band via the AWS CLI (see
  # apply-phase-5d-audit-hardening-v3.ps1) because the AWS Terraform
  # provider's object_lock_enabled argument forces bucket replacement
  # on existing buckets. Retention rules are managed by the
  # aws_s3_bucket_object_lock_configuration resource below.
  lifecycle {
    ignore_changes = [object_lock_configuration]
  }
}
'@
    # Normalise the heredoc to LF (it may have CRLF from PowerShell)
    $newBlock = $newBlock -replace "`r`n", "`n"

    # Replace the original block with the new block
    $content = $content.Substring(0, $openIdx) + $newBlock + $content.Substring($closeIdx + 1)

    # Append the lock-config resource at end of file
    $newResource = @'


# Phase 5D: Object Lock retention policy for the audit bucket.
#
# GOVERNANCE mode + 1-day retention is the demo-environment config.
# Production deployment for a real tenant would set this to COMPLIANCE
# mode + the customer's required retention period (typically 7 years
# for FDA records, 6 years for Health Canada CMDR Section 60).
#
# GOVERNANCE mode allows authorised IAM principals with the
# s3:BypassGovernanceRetention permission to override locks - the right
# balance for a demo: real protection, reversible if needed. COMPLIANCE
# mode cannot be overridden by anyone, including AWS root, until
# retention expires.
resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 1
    }
  }
}
'@
    $newResource = $newResource -replace "`r`n", "`n"
    $content = $content.TrimEnd() + $newResource + "`n"

    # Write back as UTF-8 with LF line endings
    [System.IO.File]::WriteAllBytes(
        (Resolve-Path $tfFile).Path,
        [System.Text.Encoding]::UTF8.GetBytes($content)
    )

    Write-Host "Step 1: s3-audit.tf patched"
    Write-Host "    - force_destroy: true -> false"
    Write-Host "    - lifecycle ignore_changes for object_lock_configuration"
    Write-Host "    - aws_s3_bucket_object_lock_configuration resource added (GOVERNANCE 1 day)"
    Write-Host ""
    Write-Host "Sanity check - new bucket block:"
    Write-Host "---"
    $verify = Get-Content $tfFile -Raw
    $verifyOpen = $verify.IndexOf('resource "aws_s3_bucket" "audit" {')
    $verifyEnd = $verify.IndexOf('resource "aws_s3_bucket_object_lock', $verifyOpen)
    Write-Host $verify.Substring($verifyOpen, $verifyEnd - $verifyOpen)
    Write-Host "---"
}

Write-Host ""

# --- Step 2: Enable Object Lock on the existing bucket via AWS CLI ---

$BUCKET = "regops-sentinel-dev-audit-1a8df723"

$lockState = "off"
try {
    $existingJson = aws s3api get-object-lock-configuration --bucket $BUCKET 2>$null
    if ($LASTEXITCODE -eq 0 -and $existingJson) {
        $existing = $existingJson | ConvertFrom-Json
        if ($existing.ObjectLockConfiguration.ObjectLockEnabled -eq "Enabled") {
            $lockState = "on"
        }
    }
} catch {}

if ($lockState -eq "on") {
    Write-Host "Step 2: Object Lock already enabled on $BUCKET - skipping"
} else {
    Write-Host "Step 2: Enabling Object Lock on $BUCKET..."
    aws s3api put-object-lock-configuration `
        --bucket $BUCKET `
        --object-lock-configuration "ObjectLockEnabled=Enabled"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Object Lock enabled at the bucket level."
    } else {
        Write-Error "Failed to enable Object Lock on $BUCKET"
        exit 1
    }
}

Write-Host ""

# --- Step 3: Backfill existing audit blobs with retention ---

$retainUntil = (Get-Date).AddDays(1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "Step 3: Backfilling existing audit blobs with retention until $retainUntil..."

$objectsJson = aws s3api list-objects-v2 `
    --bucket $BUCKET `
    --prefix "audit/" `
    --query "Contents[].Key" `
    --output json
$objects = if ($objectsJson -and $objectsJson -ne "null") {
    $objectsJson | ConvertFrom-Json
} else { @() }

if (-not $objects -or $objects.Count -eq 0) {
    Write-Host "    No objects found under audit/ prefix - skipping backfill"
} else {
    $total = $objects.Count
    $done = 0
    $skipped = 0
    $failed = 0
    foreach ($key in $objects) {
        $result = aws s3api put-object-retention `
            --bucket $BUCKET `
            --key $key `
            --retention "Mode=GOVERNANCE,RetainUntilDate=$retainUntil" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $done++
        } else {
            $resultStr = $result -join " "
            if ($resultStr -match "already has a retention" -or
                $resultStr -match "RetainUntilDateIsLessThanExistingRetainUntilDate") {
                $skipped++
            } else {
                $failed++
                Write-Host "    WARN: $key : $resultStr"
            }
        }
    }
    Write-Host "    Backfill complete: $done locked, $skipped skipped, $failed failed (of $total total)"
}

Write-Host ""

# --- Step 4: terraform plan ---

Write-Host "Step 4: Running terraform plan to verify the change is in-place..."
Write-Host "    (This will NOT apply; review the plan output before running terraform apply.)"
Write-Host ""

Push-Location terraform\environments\dev
try {
    terraform plan -compact-warnings
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "==================================================================="
Write-Host "Phase 5D step 4 complete. Review the plan above."
Write-Host ""
Write-Host "If the plan shows ONLY:"
Write-Host "  ~ aws_s3_bucket.audit (force_destroy true -> false + lifecycle added)"
Write-Host "  + aws_s3_bucket_object_lock_configuration.audit (new)"
Write-Host ""
Write-Host "...then run:    terraform -chdir=terraform\environments\dev apply"
Write-Host ""
Write-Host "If the plan shows aws_s3_bucket.audit being DESTROYED + recreated,"
Write-Host "STOP and report back. Do NOT apply."
Write-Host "==================================================================="
