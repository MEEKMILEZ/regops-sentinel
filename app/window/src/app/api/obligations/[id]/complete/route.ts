// BFF: POST /api/obligations/[id]/complete
//
// Marks the obligation as completed. Idempotent on the Brain side:
// if already completed, the existing completed_at is preserved and
// 200 is still returned (versus PATCH which would update completed_at
// to NOW() each time). The Brain writes an audit blob with the before
// snapshot showing the previous status.
//
// Kept as its own route handler rather than collapsing into PATCH
// because the semantics differ: PATCH is for partial-field updates,
// "complete" is a domain action with side effects (sets status,
// timestamp, and writes a distinctly-actioned audit blob with
// action=obligation_complete instead of action=obligation_update).

import { NextRequest, NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type { ObligationListItem } from "@/lib/types"

export const dynamic = "force-dynamic"
export const revalidate = 0

interface RouteParams {
  params: Promise<{ id: string }>
}

export async function POST(_req: NextRequest, { params }: RouteParams) {
  const { id } = await params

  const result = await proxyToBrain<ObligationListItem>(
    `/obligations/${encodeURIComponent(id)}/complete`,
    {
      method: "POST",
    },
  )

  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
