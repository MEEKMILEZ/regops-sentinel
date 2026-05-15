// BFF: GET /api/audit
// Lists the signed-in user's audit events. tenant_id is taken from
// their JWT on the Brain side, not from any client input.

import { NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type { AuditListResponse } from "@/lib/types"

// Disable any caching at the Next.js layer. Audit data is the
// regulatory record of record and must reflect what the Brain holds.
// Stale data here would be misleading at best, dangerous at worst.
export const dynamic = "force-dynamic"
export const revalidate = 0

export async function GET() {
  // Limit 100 is sized to comfortably cover the current tenant's audit
  // history (under 100 events) in a single fetch, matching the alerts
  // pattern of "fetch all then client-paginate." When tenants
  // accumulate more than ~100 events, swap this for cursor-based
  // pagination using the next_cursor field the Brain already returns.
  const result = await proxyToBrain<AuditListResponse>("/audit?limit=100")
  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
