// BFF: GET /api/devices/upload/[job_id]
// Returns current job state so the UI can render progress. The Brain
// already does tenant scoping from the JWT claim, so callers cannot
// peek at other tenants' jobs.

import { NextRequest, NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type { DeviceUploadJob } from "@/lib/types"

export const dynamic = "force-dynamic"
export const revalidate = 0

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ job_id: string }> },
) {
  const { job_id } = await params

  // Defensive: don't even hit the Brain if the path param is obviously
  // not a UUID. The Brain enforces this too (and 404s on malformed UUIDs)
  // but a fast-path 404 saves one upstream hop on garbage inputs.
  const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  if (!uuidRe.test(job_id)) {
    return NextResponse.json(
      { error: "not_found", status: 404, details: "Invalid job id format" },
      { status: 404 },
    )
  }

  const result = await proxyToBrain<DeviceUploadJob>(
    `/devices/upload/${encodeURIComponent(job_id)}`,
  )
  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
