# Source Zips for CodeBuild on Windows — Path Separators, Module Loading, and Cancel Semantics

**Status:** Resolved (workarounds documented)
**Date:** 2026-05-09
**Affected component:** CodeBuild project `regops-sentinel-dev-brain-build-1a8df723`, source uploaded from a Windows 10 PowerShell host

## The setup

The Brain CodeBuild project is configured with `source.type = NO_SOURCE`. Each build is started manually with `aws codebuild start-build --source-type-override S3 --source-location-override <bucket>/<key>`, where the key points to a zip I prepared on my laptop. The zip needs to extract on the Linux build container with paths matching what the inline buildspec expects (`cd app/brain` followed by `docker build .`).

That sounds easy. It produces several distinct ways to fail.

## Issue 1 — `Compress-Archive` blocked by execution policy

```powershell
Compress-Archive -Path "app\brain" -DestinationPath "$env:TEMP\brain-source.zip"
```

```
Compress-Archive : The 'Compress-Archive' command was found in the module 'Microsoft.PowerShell.Archive',
but the module could not be loaded.
```

The `Microsoft.PowerShell.Archive` module ships as a `.psm1` script. My execution policy is `Restricted`, which blocks unsigned scripts from loading. The cmdlet exists in the catalog but the runtime won't let it run.

Two ways to work around it without weakening the execution policy:

**Option A — Python's zipfile module** (works if you have Python on PATH):

```powershell
py -c "import zipfile, os; z = zipfile.ZipFile('brain-source.zip', 'w', zipfile.ZIP_DEFLATED); [z.write(os.path.join(r, f), os.path.relpath(os.path.join(r, f), '.').replace(os.sep, '/')) for r, _, files in os.walk('app') for f in files]; z.close()"
```

**Option B — Windows built-in `tar`** (works on Windows 10 1803+):

```powershell
tar -a -c -f "$env:TEMP\brain-source.zip" app/brain
```

The `-a` flag picks the archive format from the file extension (`.zip` → zip), `-c` is create, `-f` is filename. This is what I now use. It's faster than the Python option and has no module-loading dependency.

Permanent fix would be `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`. I haven't applied it because the workarounds work fine and I prefer to keep the policy strict.

## Issue 2 — `.NET ZipFile.CreateFromDirectory` writes Windows backslashes

I tried this as a `Compress-Archive` alternative:

```powershell
[System.IO.Compression.ZipFile]::CreateFromDirectory($staging.FullName, "$PWD\brain-source.zip")
```

The resulting zip had paths like `app\brain\Dockerfile`. CodeBuild's Linux extractor didn't normalize them. The buildspec's `cd app/brain` then failed with "No such file or directory" because the actual extracted item was a single file or directory literally named `app\brain\Dockerfile`, not a nested path.

Both workarounds in Issue 1 produce zips with forward slashes:

- The Python approach calls `.replace(os.sep, '/')` on every path before writing.
- `tar` always uses forward slashes regardless of host OS.

Verifying the zip before upload:

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead("$env:TEMP\brain-source.zip")
$zip.Entries | Select-Object FullName
$zip.Dispose()
```

Want to see entries like `app/brain/Dockerfile`. If you see `app\brain\Dockerfile`, the zip is broken for CodeBuild.

## Issue 3 — `aws codebuild stop-build` is asynchronous

When I tried to cancel build #2 (which had pulled an old zip from S3), `stop-build` returned status `STOPPED` immediately. The running build container ignored the signal and continued through `BUILD` and `POST_BUILD`. The final image was pushed to ECR before the agent acknowledged the cancellation. The CloudWatch log shows this clearly with `Error calling FinishContainerAction: Build is not in-progress` repeating after the push completed.

Lesson: **always verify what was actually pushed to ECR after a `stop-build`.** Don't assume the cancellation took effect mid-phase. If you see a new image digest appear in ECR after a stop, you have to either retag, delete, or accept it.

```powershell
aws ecr describe-images `
  --repository-name regops-sentinel-dev-brain-1a8df723 `
  --query "sort_by(imageDetails,& imagePushedAt)[*].{tag:imageTags[0], pushed:imagePushedAt, digest:imageDigest}" `
  --output table `
  --profile regops-sentinel `
  --region ca-central-1
```

## Issue 4 — ECR scan results lag behind image push

Right after a successful push, `aws ecr describe-images` returns `imageScanStatus: None` and `findingSeverityCounts: None`. The scan does run automatically because the repository has `scan_on_push = true`, but it takes 30–90 seconds to finish and write results back to the API.

`describe-image-scan-findings` returns the live state correctly during this window:

```powershell
aws ecr describe-image-scan-findings `
  --repository-name regops-sentinel-dev-brain-1a8df723 `
  --image-id imageTag=latest `
  --query "{status:imageScanStatus.status, severityCounts:imageScanFindings.findingSeverityCounts}" `
  --profile regops-sentinel `
  --region ca-central-1
```

If you check `describe-images` too eagerly, the cached summary fields make it look like the scan didn't run. It did. Wait a minute and retry, or use `describe-image-scan-findings`.

## Issue 5 — `aws ecr start-image-scan` quota is one scan per image per 24 hours

When I tried to manually re-trigger a scan after fixing something, I got:

```
LimitExceededException: The scan quota per image has been exceeded
```

The auto-scan from `scan_on_push` had already used that day's quota. To force another scan, I had to either push a new image (different digest) or wait 24 hours. Worth knowing if you're iterating on a Dockerfile and want repeat scans.

## Issue 6 — Notepad's Save As auto-appends `.txt`

The original Dockerfile ended up as `Dockerfile.txt` because Notepad added the extension silently. Docker's `docker build` requires a file literally named `Dockerfile` with no extension; it does not fall back to `.txt`. I fixed it with:

```powershell
Rename-Item -Path "Dockerfile.txt" -NewName "Dockerfile"
```

When saving Dockerfiles in Notepad, set "Save as type: All Files (\*.\*)" before typing the filename, or rename after.

## Lessons

- **`tar -a -c -f` is the cleanest way to make a CodeBuild-compatible zip from PowerShell.** No module loading, no path-separator surprises, no execution policy fight.
- **Always inspect zip entries before upload.** A two-second check beats a four-minute build that fails on `cd app/brain`.
- **`stop-build` is best-effort, not guaranteed.** Plan for the build to finish and push regardless.
- **ECR's two scan APIs return different staleness.** Use `describe-image-scan-findings` for live results.
- **One ECR scan per image per 24 hours.** Push a new digest if you need to rescan.
- **Notepad will add `.txt` silently.** Use "All Files" in the save dialog or rename after.
