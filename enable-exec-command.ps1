# enable-exec-command.ps1
# Enables aws ecs execute-command on the brain service.
# Adds enable_execute_command = true to aws_ecs_service.brain.

$ErrorActionPreference = "Stop"

$brainTf = "terraform\environments\dev\ecs-brain-service.tf"
$tfContent = Get-Content $brainTf -Raw

if ($tfContent -match "enable_execute_command\s*=\s*true") {
    Write-Host "enable_execute_command already true - skipping"
} else {
    $anchor = 'resource "aws_ecs_service" "brain" {'
    if ($tfContent -notmatch [regex]::Escape($anchor)) {
        Write-Error "Could not find aws_ecs_service.brain resource in $brainTf"
        exit 1
    }
    $replacement = "$anchor`r`n  enable_execute_command = true"
    $tfContent = $tfContent -replace [regex]::Escape($anchor), $replacement
    Set-Content -Path $brainTf -Value $tfContent -NoNewline
    Write-Host "ecs-brain-service.tf patched"
}

Write-Host ""
Write-Host "--- Verify ---"
Get-Content $brainTf | Select-String -Pattern 'enable_execute_command|aws_ecs_service.*brain' | Select-Object LineNumber, Line | Format-Table -AutoSize
