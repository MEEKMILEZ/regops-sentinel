\# UTF-8 BOM in Secrets Manager Payload — Brain SQS Worker Failed Silently



\*\*Status:\*\* Resolved

\*\*Date:\*\* 2026-05-09

\*\*Affected component:\*\* Brain (`app/brain/src/`) reading the Azure OpenAI secret from AWS Secrets Manager



\## The symptom



The Brain Fargate task started cleanly, the ALB target group reported it healthy, and `/health` returned `200 OK`. But classifications never appeared in the database. The SQS ingestion queue grew, messages timed out and went to the DLQ, and there was no Python exception in CloudWatch Logs to point at.



The healthcheck was passing because the FastAPI app was alive. The work loop was dead.



\## Tracing it



I added a temporary debug endpoint (`/debug/secret`, since removed) that fetched the Azure OpenAI secret from Secrets Manager and reported metadata: byte length, first 5 chars, last 5 chars, and a flag for whether the first character was `{`.



The secret length was 232 bytes. The expected JSON payload was 229 characters. The first character flag returned `false`. Three extra bytes at the start of the file, and the JSON parser was choking on them silently because the worker thread caught the exception and logged it to a logger handler that was never configured.



Those three bytes were `0xEF 0xBB 0xBF` — the UTF-8 byte order mark.



\## Why the BOM got there



When I first wrote the secret, I used PowerShell's `Set-Content` with `-Encoding UTF8`:



```powershell

Set-Content -Path payload.json -Value $payload -Encoding UTF8

aws secretsmanager put-secret-value `

&#x20; --secret-id regops-sentinel-dev-azure-openai-1a8df723 `

&#x20; --secret-string file://payload.json `

&#x20; --profile regops-sentinel `

&#x20; --region ca-central-1

```



In Windows PowerShell 5.1, `-Encoding UTF8` writes a UTF-8 file \*\*with BOM\*\*. AWS Secrets Manager stored those three leading bytes verbatim. Python's `json.loads` rejected the resulting string because BOM isn't whitespace and isn't a valid JSON token.



PowerShell 7 changed the default — `-Encoding UTF8` there means BOM-less. PowerShell 5.1 callers have to explicitly use `-Encoding utf8NoBOM` (which doesn't exist in 5.1) or fall through to .NET to get a clean file.



\## The fix



Write the secret payload using the .NET `UTF8Encoding` constructor with the `encoderShouldEmitUTF8Identifier` flag set to `false`:



```powershell

$payload = \[PSCustomObject]@{

&#x20;   endpoint = "https://rg-regops-sentinel-dev.openai.azure.com/"

&#x20;   api\_key = $plainKey

&#x20;   deployment\_name = "gpt-4o-regops"

&#x20;   api\_version = "2024-12-01-preview"

} | ConvertTo-Json -Compress



$tmpfile = "$env:TEMP\\azure-secret-payload.json"



$utf8NoBom = New-Object System.Text.UTF8Encoding $false

\[System.IO.File]::WriteAllText($tmpfile, $payload, $utf8NoBom)



aws secretsmanager put-secret-value `

&#x20; --secret-id regops-sentinel-dev-azure-openai-1a8df723 `

&#x20; --secret-string "file://$tmpfile" `

&#x20; --profile regops-sentinel `

&#x20; --region ca-central-1



Remove-Item $tmpfile

```



The `New-Object System.Text.UTF8Encoding $false` is the key line. The `$false` argument tells .NET not to emit the BOM identifier when writing.



\## Verification



Before pushing the fix, I verified the local file was clean by reading the first byte:



```powershell

$firstByte = \[System.IO.File]::ReadAllBytes($tmpfile)\[0]

"First byte: 0x{0:X2} (should be 0x7B for ASCII '{{')" -f $firstByte

```



Expected output: `First byte: 0x7B`. That's `{`, the start of the JSON object. If you see `0xEF` instead, you have a BOM.



After the put-secret-value, I hit `/debug/secret` again and confirmed:



\- `secret\_length: 229` (down from 232)

\- `is\_valid\_json\_first\_char: true`



The Brain worker thread came back to life, drained the SQS backlog, and started writing classifications to RDS and audit blobs to S3.



\## Why the worker swallowed the exception



The Brain's SQS poll loop has a try/except around each message that logs the exception and continues. The intent was to keep the worker alive when one bad message comes through, instead of crashing the whole task. The unintended consequence: a configuration error that affected every message looked exactly like "no messages arriving."



I'm not changing the broad except — it's correct for production durability — but for Phase 4 I'm adding a CloudWatch metric for `worker.classification\_failed` so the silent-failure mode can't happen again. If the metric goes nonzero for more than five minutes, an alarm will fire.



\## Lessons



\- \*\*PowerShell 5.1 `-Encoding UTF8` writes BOM.\*\* Always use the .NET `UTF8Encoding $false` pattern for any file that downstream parsers will read as bytes.

\- \*\*A passing healthcheck is not a passing worker.\*\* Add a separate liveness signal for any background thread that does the actual work.

\- \*\*A silent broad except is worse than a crash for diagnosing config problems.\*\* Pair it with a metric.

