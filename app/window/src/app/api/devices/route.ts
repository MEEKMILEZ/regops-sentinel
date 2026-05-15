// BFF: GET /api/devices
// Lists the signed-in user's device catalog. tenant_id comes from the
// JWT on the Brain side; no client input can override it.

import { NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type { DevicesListResponse } from "@/lib/types"

// No caching: device catalog is tenant-scoped and tied to regulatory
// status (recalls happen, classifications change). Always hit the
// Brain for freshness.
export const dynamic = "force-dynamic"
export const revalidate = 0

export async function GET() {
  const result = await proxyToBrain<DevicesListResponse>("/devices?limit=100")
  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
