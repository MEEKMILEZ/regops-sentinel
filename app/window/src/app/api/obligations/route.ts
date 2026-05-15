// BFF: GET /api/obligations
// Lists the signed-in user's regulatory obligations. tenant_id comes
// from the JWT on the Brain side; no client input can override it.

import { NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type { ObligationsListResponse } from "@/lib/types"

// No caching: obligations are time-sensitive. An obligation due
// today must not be cached as "upcoming" from a 5-minute-old fetch.
export const dynamic = "force-dynamic"
export const revalidate = 0

export async function GET() {
  const result =
    await proxyToBrain<ObligationsListResponse>("/obligations?limit=100")
  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
