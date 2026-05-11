// BFF: GET /api/alerts
// Lists the signed-in user's alerts. tenant_id is taken from their JWT
// on the Brain side, not from any client input.

import { NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type { AlertsListResponse } from "@/lib/types"

// Disable any caching at the Next.js layer for this handler. Tenant-
// scoped, user-scoped data should never be cached by us; Brain is the
// system of record and the only authority on freshness.
export const dynamic = "force-dynamic"
export const revalidate = 0

export async function GET() {
  const result = await proxyToBrain<AlertsListResponse>("/alerts")
  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
