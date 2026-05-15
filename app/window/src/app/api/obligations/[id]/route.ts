// BFF: PATCH /api/obligations/[id] and DELETE /api/obligations/[id]
//
// PATCH  - Updates fields on an existing obligation. Body is a partial
//          JSON payload; only the fields present are changed. Brain
//          enforces tenant scoping (404 if obligation belongs to a
//          different tenant) and validates enum membership for any
//          fields supplied. Brain writes an audit blob with before/
//          after snapshots before the row is mutated.
// DELETE - Hard-deletes the obligation row from the operational DB.
//          Brain writes a final audit blob with the pre-deletion
//          snapshot BEFORE issuing the DB delete, so the audit trail
//          is preserved even if the delete itself fails. Returns 200
//          with the deleted row as a snapshot.
//
// The complete action lives at [id]/complete/route.ts because the Brain
// exposes it as POST /obligations/{id}/complete (a distinct endpoint
// from generic PATCH, with idempotent set-status-and-completed_at).

import { NextRequest, NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type { ObligationListItem } from "@/lib/types"

export const dynamic = "force-dynamic"
export const revalidate = 0

interface RouteParams {
  params: Promise<{ id: string }>
}

export async function PATCH(req: NextRequest, { params }: RouteParams) {
  const { id } = await params
  const body = await req.text()

  const result = await proxyToBrain<ObligationListItem>(
    `/obligations/${encodeURIComponent(id)}`,
    {
      method: "PATCH",
      headers: {
        "content-type": "application/json",
      },
      body,
    },
  )

  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}

export async function DELETE(_req: NextRequest, { params }: RouteParams) {
  const { id } = await params

  // The DELETE response from the Brain is shaped
  // { deleted: true, obligation: {...snapshot} }.
  // We type it loosely here since the form/row-actions code only checks
  // `result.ok`.
  const result = await proxyToBrain<{
    deleted: boolean
    obligation: ObligationListItem
  }>(`/obligations/${encodeURIComponent(id)}`, {
    method: "DELETE",
  })

  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
