// BFF: GET /api/obligations and POST /api/obligations
//
// GET   - Lists the signed-in user's regulatory obligations. tenant_id
//         comes from the JWT on the Brain side; no client input can
//         override it.
// POST  - Creates a new obligation under the user's tenant. The body
//         is a JSON payload forwarded verbatim to the Brain; the Brain
//         is the canonical validator (required fields, enum membership,
//         field interdependencies like due_at-required-when-recurring
//         and device_id-required-for-mdl_renewal). Client-side validation
//         in the form component is purely a UX nicety.

import { NextRequest, NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type {
  ObligationListItem,
  ObligationsListResponse,
} from "@/lib/types"

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

export async function POST(req: NextRequest) {
  // Read the JSON body as text and forward verbatim. We don't parse and
  // re-serialize because (a) it doubles work, and (b) any parsing here
  // would create a second place validation rules could drift.
  const body = await req.text()

  const result = await proxyToBrain<ObligationListItem>("/obligations", {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body,
  })

  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
