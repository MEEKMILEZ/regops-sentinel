"use client"

import * as React from "react"
import { useRouter } from "next/navigation"
import {
  AlertTriangle,
  CheckCircle2,
  Loader2,
  Upload,
  X,
  XCircle,
} from "lucide-react"

import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { cn } from "@/lib/utils"

import type {
  DeviceUploadJob,
  DeviceUploadJobCreateResponse,
} from "@/lib/types"

// ----------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------

// Mirror the Brain's hard cap (DEVICE_UPLOAD_MAX_BYTES = 1024 * 1024).
// Fail-fast client-side gives a better error message than waiting for
// the 413 from upstream.
const MAX_UPLOAD_BYTES = 1024 * 1024

// Preview shows at most this many data rows (excluding the header row).
const PREVIEW_ROW_LIMIT = 10

// Polling interval while a job is queued/processing. 1500ms is the same
// cadence we used in the smoke test - fast enough to feel responsive on
// the 269ms-typical job, gentle enough to not hammer the BFF.
const POLL_INTERVAL_MS = 1500

// Polling timeout safety. The Brain's worker is synchronous within the
// daemon thread; 60s is several orders of magnitude beyond observed
// processing time even at the 1MB hard cap. If we hit this, something
// is wrong upstream and we should surface that to the user rather than
// spin forever.
const POLL_TIMEOUT_MS = 60_000

// localStorage key for the in-flight job id. Scoped per-tenant would be
// ideal, but the tenant isn't readily available on the client without
// an extra fetch. Acceptable because the Brain returns 404 on cross-
// tenant lookups anyway - the worst case is we briefly poll a job that
// belongs to a different tenant in the same browser, then clear it.
const RESUMABLE_JOB_KEY = "regops-sentinel:device-upload:job-id"

// ----------------------------------------------------------------------
// localStorage helpers - safe under SSR / strict mode
// ----------------------------------------------------------------------

function readStoredJobId(): string | null {
  if (typeof window === "undefined") return null
  try {
    return window.localStorage.getItem(RESUMABLE_JOB_KEY)
  } catch {
    return null
  }
}

function writeStoredJobId(jobId: string): void {
  if (typeof window === "undefined") return
  try {
    window.localStorage.setItem(RESUMABLE_JOB_KEY, jobId)
  } catch {
    // Quota exceeded, private browsing, etc. Non-fatal.
  }
}

function clearStoredJobId(): void {
  if (typeof window === "undefined") return
  try {
    window.localStorage.removeItem(RESUMABLE_JOB_KEY)
  } catch {
    // Non-fatal.
  }
}

// ----------------------------------------------------------------------
// CSV preview parser - just enough to show the first N rows
// ----------------------------------------------------------------------

interface CsvPreview {
  header: string[]
  rows: string[][]
  totalDataRows: number
  truncated: boolean
}

// Naive splitter. MDALL exports don't quote fields (they're already
// licence numbers, device names, etc., none with embedded commas in
// practice). For a production upload form we'd use Papa Parse; here
// we keep dependencies minimal.
function parseCsvPreview(text: string): CsvPreview {
  const lines = text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0)

  if (lines.length === 0) {
    return { header: [], rows: [], totalDataRows: 0, truncated: false }
  }

  const header = lines[0].split(",").map((c) => c.trim())
  const dataLines = lines.slice(1)
  const rows = dataLines
    .slice(0, PREVIEW_ROW_LIMIT)
    .map((l) => l.split(",").map((c) => c.trim()))

  return {
    header,
    rows,
    totalDataRows: dataLines.length,
    truncated: dataLines.length > PREVIEW_ROW_LIMIT,
  }
}

// ----------------------------------------------------------------------
// Component
// ----------------------------------------------------------------------

type Phase =
  | "idle"
  | "preview"
  | "uploading"
  | "polling"
  | "complete"
  | "failed"

interface UploadFlowProps {
  // Called after a successful upload completes. Lets the parent page
  // refresh its server data (typically router.refresh()).
  onComplete?: () => void
}

export function UploadFlow({ onComplete }: UploadFlowProps) {
  const router = useRouter()
  const fileInputRef = React.useRef<HTMLInputElement>(null)

  const [phase, setPhase] = React.useState<Phase>("idle")
  const [selectedFile, setSelectedFile] = React.useState<File | null>(null)
  const [csvText, setCsvText] = React.useState<string>("")
  const [preview, setPreview] = React.useState<CsvPreview | null>(null)
  const [jobId, setJobId] = React.useState<string | null>(null)
  const [job, setJob] = React.useState<DeviceUploadJob | null>(null)
  const [errorMessage, setErrorMessage] = React.useState<string | null>(null)

  // ------------------------------------------------------------------
  // Polling loop - re-runs whenever jobId changes
  // ------------------------------------------------------------------

  React.useEffect(() => {
    if (!jobId) return
    if (phase !== "polling") return

    let cancelled = false
    const startedAt = Date.now()

    async function tick() {
      if (cancelled) return

      // Timeout guard: surface a friendly error rather than spin forever.
      if (Date.now() - startedAt > POLL_TIMEOUT_MS) {
        setErrorMessage(
          "Upload is taking longer than expected. The job may still complete in the background; refresh the page to check the device catalog.",
        )
        setPhase("failed")
        clearStoredJobId()
        return
      }

      try {
        const res = await fetch(`/api/devices/upload/${jobId}`, {
          cache: "no-store",
        })

        if (res.status === 404) {
          // Job no longer exists (different tenant, or expired). Clear
          // and surface a generic message.
          clearStoredJobId()
          if (!cancelled) {
            setErrorMessage("Upload job not found. It may have expired.")
            setPhase("failed")
          }
          return
        }

        if (!res.ok) {
          // Transient upstream issue - keep polling. The timeout above
          // will eventually fire if it never recovers.
          setTimeout(tick, POLL_INTERVAL_MS)
          return
        }

        const next = (await res.json()) as DeviceUploadJob
        if (cancelled) return
        setJob(next)

        if (next.status === "complete") {
          clearStoredJobId()
          setPhase("complete")
          // Refresh the parent server component so the new devices show
          // up in the table immediately.
          if (onComplete) {
            onComplete()
          } else {
            router.refresh()
          }
          return
        }

        if (next.status === "failed") {
          clearStoredJobId()
          setErrorMessage(
            next.failure_reason ?? "Upload failed for an unknown reason.",
          )
          setPhase("failed")
          return
        }

        // Still queued or processing - keep polling.
        setTimeout(tick, POLL_INTERVAL_MS)
      } catch {
        // Network error fetching status - keep polling; timeout will
        // surface the failure if it persists.
        setTimeout(tick, POLL_INTERVAL_MS)
      }
    }

    tick()
    return () => {
      cancelled = true
    }
  }, [jobId, phase, onComplete, router])

  // ------------------------------------------------------------------
  // Resume on mount: if a job id is in localStorage, recover it
  // ------------------------------------------------------------------

  React.useEffect(() => {
    const storedId = readStoredJobId()
    if (!storedId) return

    let cancelled = false

    async function recover() {
      try {
        const res = await fetch(`/api/devices/upload/${storedId}`, {
          cache: "no-store",
        })
        if (cancelled) return

        if (res.status === 404) {
          // Stale or cross-tenant; just clear silently.
          clearStoredJobId()
          return
        }
        if (!res.ok) {
          // Don't surface this - it's a background recovery.
          return
        }

        const data = (await res.json()) as DeviceUploadJob
        if (cancelled) return

        setJob(data)
        setJobId(data.job_id)

        if (data.status === "queued" || data.status === "processing") {
          // Resume the polling UI.
          setPhase("polling")
        } else if (data.status === "complete") {
          // Show the user the results they missed.
          setPhase("complete")
          // Clear so we don't pop the modal on subsequent loads.
          clearStoredJobId()
        } else if (data.status === "failed") {
          setErrorMessage(
            data.failure_reason ?? "Upload failed for an unknown reason.",
          )
          setPhase("failed")
          clearStoredJobId()
        }
      } catch {
        // Background recovery failure is silent.
      }
    }

    recover()
    return () => {
      cancelled = true
    }
    // Intentionally only on mount; we don't want to re-recover when
    // jobId / phase change in normal flow.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // ------------------------------------------------------------------
  // Handlers
  // ------------------------------------------------------------------

  function openPicker() {
    fileInputRef.current?.click()
  }

  async function onFilePicked(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    // Reset the input so the same file can be re-selected after a cancel.
    e.target.value = ""
    if (!file) return

    if (file.size > MAX_UPLOAD_BYTES) {
      setErrorMessage(
        `File is ${(file.size / 1024).toFixed(0)} KB, which exceeds the 1 MB upload limit.`,
      )
      setPhase("failed")
      return
    }

    // Read the file as text. Large files (close to 1MB) take a moment.
    const text = await file.text()
    const parsed = parseCsvPreview(text)

    if (parsed.header.length === 0 || parsed.totalDataRows === 0) {
      setErrorMessage(
        "The file is empty or has no data rows. Expected a CSV with a header row and at least one device row.",
      )
      setPhase("failed")
      return
    }

    setSelectedFile(file)
    setCsvText(text)
    setPreview(parsed)
    setPhase("preview")
  }

  async function startUpload() {
    if (!csvText || !selectedFile) return

    setPhase("uploading")
    setErrorMessage(null)

    try {
      const res = await fetch("/api/devices/upload", {
        method: "POST",
        headers: {
          "content-type": "text/csv",
          "x-upload-filename": selectedFile.name,
        },
        body: csvText,
      })

      if (!res.ok) {
        let detail: string | null = null
        try {
          const body = await res.json()
          detail =
            (body && typeof body === "object" && "details" in body
              ? String((body as { details: unknown }).details)
              : null) ?? null
        } catch {
          // Non-JSON error body.
        }
        setErrorMessage(
          detail ??
            `Upload failed with status ${res.status}. Please try again.`,
        )
        setPhase("failed")
        return
      }

      const data = (await res.json()) as DeviceUploadJobCreateResponse
      writeStoredJobId(data.job_id)
      setJobId(data.job_id)
      setJob(null) // First poll will populate
      setPhase("polling")
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Network error during upload."
      setErrorMessage(message)
      setPhase("failed")
    }
  }

  function reset() {
    setSelectedFile(null)
    setCsvText("")
    setPreview(null)
    setJobId(null)
    setJob(null)
    setErrorMessage(null)
    setPhase("idle")
  }

  function cancelPreview() {
    reset()
  }

  // Modal is open whenever we're in any non-idle phase.
  const open = phase !== "idle"

  function onOpenChange(next: boolean) {
    if (next) return
    // Only allow closing from terminal phases. Don't let the user close
    // mid-upload (they'd lose the modal but the upload keeps going via
    // localStorage; better UX is to not allow close at all during the
    // active phases).
    if (phase === "complete" || phase === "failed") {
      reset()
    }
  }

  return (
    <>
      <input
        ref={fileInputRef}
        type="file"
        accept=".csv,text/csv"
        className="hidden"
        onChange={onFilePicked}
      />
      <Button onClick={openPicker} size="sm">
        <Upload className="size-4" />
        Upload CSV
      </Button>

      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent className="sm:max-w-2xl">
          {phase === "preview" && preview ? (
            <PreviewView
              filename={selectedFile?.name ?? ""}
              fileSize={selectedFile?.size ?? 0}
              preview={preview}
              onCancel={cancelPreview}
              onConfirm={startUpload}
            />
          ) : null}

          {(phase === "uploading" || phase === "polling") && (
            <ProgressView
              filename={selectedFile?.name ?? job?.filename ?? "upload"}
              job={job}
              uploading={phase === "uploading"}
            />
          )}

          {phase === "complete" && job ? (
            <CompleteView
              job={job}
              filename={selectedFile?.name ?? job.filename ?? "upload"}
              onClose={reset}
            />
          ) : null}

          {phase === "failed" ? (
            <FailedView
              message={errorMessage ?? "Upload failed."}
              onClose={reset}
            />
          ) : null}
        </DialogContent>
      </Dialog>
    </>
  )
}

// ----------------------------------------------------------------------
// Sub-views: each phase is its own JSX block, kept small for clarity
// ----------------------------------------------------------------------

function PreviewView({
  filename,
  fileSize,
  preview,
  onCancel,
  onConfirm,
}: {
  filename: string
  fileSize: number
  preview: CsvPreview
  onCancel: () => void
  onConfirm: () => void
}) {
  return (
    <>
      <DialogHeader>
        <DialogTitle>Preview upload</DialogTitle>
        <DialogDescription>
          {filename} ({(fileSize / 1024).toFixed(1)} KB) ·{" "}
          {preview.totalDataRows} device row
          {preview.totalDataRows === 1 ? "" : "s"} detected
        </DialogDescription>
      </DialogHeader>

      <div className="overflow-x-auto rounded-md border">
        <table className="w-full text-xs">
          <thead className="bg-muted/40">
            <tr>
              {preview.header.map((h, i) => (
                <th key={i} className="px-3 py-2 text-left font-medium">
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {preview.rows.map((row, ri) => (
              <tr key={ri} className="border-t">
                {row.map((cell, ci) => (
                  <td
                    key={ci}
                    className="text-muted-foreground px-3 py-2 font-mono"
                  >
                    {cell || "—"}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {preview.truncated ? (
        <p className="text-muted-foreground text-xs">
          Showing first {PREVIEW_ROW_LIMIT} of {preview.totalDataRows} rows.
          All rows will be uploaded.
        </p>
      ) : null}

      <p className="text-muted-foreground text-xs">
        Expected columns from Health Canada MDALL exports: LICENCE_NO,
        DEVICE_NAME, MODEL_IDENTIFIER, COMPANY_NAME, DEVICE_CLASS,
        LICENCE_STATUS, UDI_DI. Existing devices (matched on UDI-DI) will be
        updated; new devices will be inserted.
      </p>

      <DialogFooter>
        <Button variant="outline" onClick={onCancel}>
          Cancel
        </Button>
        <Button onClick={onConfirm}>Confirm upload</Button>
      </DialogFooter>
    </>
  )
}

function ProgressView({
  filename,
  job,
  uploading,
}: {
  filename: string
  job: DeviceUploadJob | null
  uploading: boolean
}) {
  const total = job?.total_rows ?? 0
  const processed = job?.processed_rows ?? 0
  const pct = total > 0 ? Math.round((processed / total) * 100) : 0

  const heading = uploading
    ? "Uploading..."
    : job?.status === "queued"
      ? "Queued..."
      : "Processing..."

  return (
    <>
      <DialogHeader>
        <DialogTitle className="flex items-center gap-2">
          <Loader2 className="size-4 animate-spin" />
          {heading}
        </DialogTitle>
        <DialogDescription>{filename}</DialogDescription>
      </DialogHeader>

      <div className="flex flex-col gap-3 py-2">
        {uploading || total === 0 ? (
          <p className="text-muted-foreground text-sm">
            {uploading
              ? "Transferring file to the server..."
              : "Waiting for the worker to start..."}
          </p>
        ) : (
          <>
            <div className="flex items-baseline justify-between text-sm">
              <span>
                {processed} of {total} rows
              </span>
              <span className="text-muted-foreground font-mono text-xs">
                {pct}%
              </span>
            </div>
            <div className="bg-muted h-2 overflow-hidden rounded-full">
              <div
                className="bg-primary h-full transition-all duration-300"
                style={{ width: `${pct}%` }}
              />
            </div>
            <div className="text-muted-foreground flex gap-4 text-xs">
              <span>{job?.inserted_count ?? 0} inserted</span>
              <span>{job?.updated_count ?? 0} updated</span>
              {job && job.error_count > 0 ? (
                <span className="text-amber-600">
                  {job.error_count} errors
                </span>
              ) : null}
            </div>
          </>
        )}
      </div>

      <p className="text-muted-foreground text-xs">
        You can close this tab; the upload will continue in the background.
        Re-open the device catalog to check status.
      </p>
    </>
  )
}

function CompleteView({
  job,
  filename,
  onClose,
}: {
  job: DeviceUploadJob
  filename: string
  onClose: () => void
}) {
  const hasErrors = job.error_count > 0

  return (
    <>
      <DialogHeader>
        <DialogTitle className="flex items-center gap-2">
          <CheckCircle2 className="size-5 text-emerald-600" />
          Upload complete
        </DialogTitle>
        <DialogDescription>{filename}</DialogDescription>
      </DialogHeader>

      <div className="grid grid-cols-3 gap-3 py-2">
        <Stat label="Inserted" value={job.inserted_count} tone="success" />
        <Stat label="Updated" value={job.updated_count} tone="neutral" />
        <Stat
          label="Errors"
          value={job.error_count}
          tone={hasErrors ? "warn" : "neutral"}
        />
      </div>

      {hasErrors && job.error_log.length > 0 ? (
        <div className="bg-muted/40 max-h-48 overflow-y-auto rounded-md border p-3">
          <p className="mb-2 text-xs font-medium">Error details:</p>
          <ul className="space-y-1 text-xs">
            {job.error_log.slice(0, 50).map((e, i) => (
              <li key={i} className="font-mono">
                Row {e.row}
                {e.di ? ` (DI ${e.di})` : ""}: {e.error}
              </li>
            ))}
          </ul>
          {job.error_count > job.error_log.length ? (
            <p className="text-muted-foreground mt-2 text-xs">
              ...and {job.error_count - job.error_log.length} more (only the
              first 50 errors are stored)
            </p>
          ) : null}
        </div>
      ) : null}

      <DialogFooter>
        <Button onClick={onClose}>Done</Button>
      </DialogFooter>
    </>
  )
}

function FailedView({
  message,
  onClose,
}: {
  message: string
  onClose: () => void
}) {
  return (
    <>
      <DialogHeader>
        <DialogTitle className="flex items-center gap-2">
          <XCircle className="size-5 text-destructive" />
          Upload failed
        </DialogTitle>
      </DialogHeader>

      <div className="bg-destructive/10 text-destructive flex items-start gap-2 rounded-md p-3 text-sm">
        <AlertTriangle className="mt-0.5 size-4 shrink-0" />
        <p>{message}</p>
      </div>

      <DialogFooter>
        <Button variant="outline" onClick={onClose}>
          Close
        </Button>
      </DialogFooter>
    </>
  )
}

function Stat({
  label,
  value,
  tone,
}: {
  label: string
  value: number
  tone: "success" | "warn" | "neutral"
}) {
  return (
    <div
      className={cn(
        "flex flex-col gap-1 rounded-md border p-3",
        tone === "success" && "border-emerald-200 bg-emerald-50/50",
        tone === "warn" && "border-amber-200 bg-amber-50/50",
      )}
    >
      <span className="text-muted-foreground text-xs">{label}</span>
      <span
        className={cn(
          "text-2xl font-semibold tabular-nums",
          tone === "success" && "text-emerald-700",
          tone === "warn" && "text-amber-700",
        )}
      >
        {value}
      </span>
    </div>
  )
}
