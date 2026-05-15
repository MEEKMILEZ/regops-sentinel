# apply-cli-client-patch.ps1
# Adds an aws_cognito_user_pool_client.cli resource to cognito.tf and a
# matching output to outputs.tf.
#
# Industry-standard rationale:
#   - Browser-facing (web) and CLI clients should be separate so their
#     auth-flow allowlists can be scoped to what each actually needs.
#   - Web client keeps USER_SRP_AUTH (browser uses SRP for password-less
#     plaintext-on-wire).
#   - CLI client gets USER_PASSWORD_AUTH because scripts can't implement
#     SRP cleanly. Shorter refresh tokens limit blast radius if leaked.

$ErrorActionPreference = "Stop"

$cognitoTf = "terraform\environments\dev\cognito.tf"
$outputsTf = "terraform\environments\dev\outputs.tf"

# --- Patch 1: cognito.tf - add cli client resource ---

$cognitoContent = Get-Content $cognitoTf -Raw

# Idempotency check
if ($cognitoContent -match 'resource "aws_cognito_user_pool_client" "cli"') {
    Write-Host "CLI client resource already exists in cognito.tf - skipping"
} else {
    # Anchor: insert AFTER the closing brace of the web client, BEFORE the
    # user_pool_domain resource. The web client block ends with the
    # token_validity_units block's closing brace then the resource's closing
    # brace. We anchor on the unique string that appears only between web
    # client and domain.

    $anchor = "resource `"aws_cognito_user_pool_domain`" `"main`" {"

    if ($cognitoContent -notmatch [regex]::Escape($anchor)) {
        Write-Error "Could not find anchor '$anchor' in cognito.tf"
        exit 1
    }

    $newResource = @'
resource "aws_cognito_user_pool_client" "cli" {
  name         = "${local.name_prefix}-cli-client-${local.full_suffix}"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  # CLI-only client. Browser-facing flows live on the `web` client and use
  # SRP. This client exists for smoke tests and operator scripts that
  # cannot implement SRP cleanly.
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  prevent_user_existence_errors = "ENABLED"

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 1

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

'@

    $newContent = $cognitoContent -replace [regex]::Escape($anchor), ($newResource + $anchor)
    Set-Content -Path $cognitoTf -Value $newContent -NoNewline
    Write-Host "cognito.tf patched - cli client resource added"
}

# --- Patch 2: outputs.tf - add cli client id output ---

$outputsContent = Get-Content $outputsTf -Raw

if ($outputsContent -match 'output "cognito_cli_client_id"') {
    Write-Host "cognito_cli_client_id output already exists in outputs.tf - skipping"
} else {
    $anchor = "output `"cognito_user_pool_client_id`" {`r`n  value = aws_cognito_user_pool_client.web.id`r`n}"

    # Try with CRLF first, fall back to LF
    $found = $false
    foreach ($lineEnding in @("`r`n", "`n")) {
        $tryAnchor = "output `"cognito_user_pool_client_id`" {$($lineEnding)  value = aws_cognito_user_pool_client.web.id$($lineEnding)}"
        if ($outputsContent -match [regex]::Escape($tryAnchor)) {
            $anchor = $tryAnchor
            $found = $true
            break
        }
    }

    if (-not $found) {
        Write-Error "Could not find the web client output block in outputs.tf - patch outputs.tf manually"
        exit 1
    }

    $newOutput = @'

output "cognito_cli_client_id" {
  value = aws_cognito_user_pool_client.cli.id
}
'@

    $newContent = $outputsContent -replace [regex]::Escape($anchor), ($anchor + $newOutput)
    Set-Content -Path $outputsTf -Value $newContent -NoNewline
    Write-Host "outputs.tf patched - cognito_cli_client_id output added"
}

# --- Verify ---
Write-Host ""
Write-Host "--- Verify cognito.tf ---"
Get-Content $cognitoTf | Select-String -Pattern 'resource "aws_cognito_user_pool_client"|resource "aws_cognito_user_pool"'

Write-Host ""
Write-Host "--- Verify outputs.tf ---"
Get-Content $outputsTf | Select-String -Pattern 'output "cognito'

Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. cd terraform\environments\dev"
Write-Host "  2. terraform plan -target=aws_cognito_user_pool_client.cli"
Write-Host "  3. terraform apply -target=aws_cognito_user_pool_client.cli"
Write-Host "  4. terraform output cognito_cli_client_id"
