# deploy-audit-endpoint.ps1
# Builds the brain container with the new /audit endpoint, rolls the ECS
# service to the new image, and smoke-tests the deployed ALB.
#
# Prerequisites:
#   - brain-source-audit-list.zip already uploaded to CodeBuild S3 bucket
#   - AWS_PROFILE=regops-sentinel and AWS_REGION=ca-central-1 already set
#
# Safe to interrupt with Ctrl+C - all AWS state changes are reversible
# (CodeBuild and ECS both keep history; nothing here is destructive).

$ErrorActionPreference = "Stop"

# --- Known good values from diagnostic ---
$PROJECT_NAME    = "regops-sentinel-dev-brain-build-1a8df723"
$CLUSTER         = "regops-sentinel-dev-cluster-1a8df723"
$CODEBUILD_BUCKET = "regops-sentinel-dev-codebuild-1a8df723"
$SOURCE_KEY      = "brain-source-audit-list.zip"
$ALB_URL         = "http://rgops-brain-alb-1a8df723-954473560.ca-central-1.elb.amazonaws.com"

# --- Find the brain service name automatically ---
Write-Host "==> Finding brain service in cluster..."
$serviceArns = aws ecs list-services --cluster $CLUSTER --query "serviceArns" --output text
$brainServiceArn = ($serviceArns -split "\s+") | Where-Object { $_ -match "brain" } | Select-Object -First 1
if (-not $brainServiceArn) {
    Write-Error "No brain service found in cluster $CLUSTER"
    Write-Host "Services found: $serviceArns"
    exit 1
}
$BRAIN_SERVICE = ($brainServiceArn -split "/")[-1]
Write-Host "    Brain service: $BRAIN_SERVICE"

# --- Step 1: Trigger CodeBuild build ---
Write-Host ""
Write-Host "==> Starting CodeBuild..."
$BUILD_ID = aws codebuild start-build `
    --project-name $PROJECT_NAME `
    --source-type-override S3 `
    --source-location-override "$CODEBUILD_BUCKET/$SOURCE_KEY" `
    --query "build.id" --output text
if (-not $BUILD_ID -or $BUILD_ID -eq "None") {
    Write-Error "Failed to start build"
    exit 1
}
Write-Host "    Build ID: $BUILD_ID"

# --- Step 2: Poll until build finishes ---
Write-Host ""
Write-Host "==> Waiting for build to complete..."
$lastPhase = ""
while ($true) {
    $status = aws codebuild batch-get-builds --ids $BUILD_ID --query "builds[0].buildStatus" --output text
    $phase  = aws codebuild batch-get-builds --ids $BUILD_ID --query "builds[0].currentPhase" --output text
    if ($phase -ne $lastPhase) {
        Write-Host "    $(Get-Date -Format 'HH:mm:ss')  status=$status  phase=$phase"
        $lastPhase = $phase
    }
    if ($status -ne "IN_PROGRESS") { break }
    Start-Sleep -Seconds 15
}
Write-Host "    Final build status: $status"

if ($status -ne "SUCCEEDED") {
    Write-Host ""
    Write-Host "BUILD FAILED - pulling last 100 log lines..."
    $logGroup  = aws codebuild batch-get-builds --ids $BUILD_ID --query "builds[0].logs.groupName"  --output text
    $logStream = aws codebuild batch-get-builds --ids $BUILD_ID --query "builds[0].logs.streamName" --output text
    aws logs get-log-events --log-group-name $logGroup --log-stream-name $logStream --limit 100 --query "events[*].message" --output text
    exit 1
}

# --- Step 3: Force ECS rollout ---
Write-Host ""
Write-Host "==> Forcing ECS service rollout..."
aws ecs update-service `
    --cluster $CLUSTER `
    --service $BRAIN_SERVICE `
    --force-new-deployment `
    --query "service.deployments[?status=='PRIMARY'].{taskDef:taskDefinition,desired:desiredCount,running:runningCount}" `
    --output table | Out-Host

# --- Step 4: Wait for rollout to stabilize ---
Write-Host ""
Write-Host "==> Waiting for service to stabilize (this typically takes 1-2 minutes)..."
$start = Get-Date
while ($true) {
    $deployments = aws ecs describe-services `
        --cluster $CLUSTER `
        --services $BRAIN_SERVICE `
        --query "services[0].deployments" `
        --output json | ConvertFrom-Json

    $primary = $deployments | Where-Object { $_.status -eq "PRIMARY" } | Select-Object -First 1
    $hasInactive = ($deployments | Where-Object { $_.status -ne "PRIMARY" }).Count -gt 0

    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    Write-Host ("    ${elapsed}s  primary running={0}/{1}  rollouts in progress={2}" -f $primary.runningCount, $primary.desiredCount, $hasInactive)

    if (-not $hasInactive -and $primary.runningCount -eq $primary.desiredCount) {
        break
    }
    if ($elapsed -gt 300) {
        Write-Warning "Service has not stabilised after 5 minutes - check ECS console for stuck tasks"
        break
    }
    Start-Sleep -Seconds 15
}

# --- Step 5: Smoke tests ---
Write-Host ""
Write-Host "==> Smoke tests..."

Write-Host ""
Write-Host "[1/2] GET /health (should return 200 + status ok)"
try {
    $health = Invoke-WebRequest -Uri "$ALB_URL/health" -UseBasicParsing -TimeoutSec 10
    Write-Host "    HTTP $($health.StatusCode)  body: $($health.Content)"
} catch {
    Write-Host "    FAILED: $_"
}

Write-Host ""
Write-Host "[2/2] GET /audit (no Authorization header - should return 401 missing_authorization)"
try {
    $resp = Invoke-WebRequest -Uri "$ALB_URL/audit" -UseBasicParsing -TimeoutSec 10
    Write-Host "    UNEXPECTED HTTP $($resp.StatusCode) - endpoint should reject unauth requests"
    Write-Host "    body: $($resp.Content)"
} catch [System.Net.WebException] {
    $statusCode = [int]$_.Exception.Response.StatusCode
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    $body = $reader.ReadToEnd()
    if ($statusCode -eq 401) {
        Write-Host "    HTTP 401 (expected)  body: $body"
        Write-Host "    /audit route is registered and auth is wired correctly"
    } else {
        Write-Host "    HTTP $statusCode  body: $body"
    }
}

Write-Host ""
Write-Host "==> Deploy complete."
Write-Host ""
Write-Host "Next step: get a real JWT and test /audit with it. Run:"
Write-Host "  .\get-jwt-and-test-audit.ps1"
Write-Host "(I will send that script next once this one verifies clean.)"
