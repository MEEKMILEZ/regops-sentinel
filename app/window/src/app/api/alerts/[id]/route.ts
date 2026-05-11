// BFF: GET /api/alerts/[id]
// Returns one alert by id. tenant scoping happens on the Brain side -
// a cross-tenant lookup returns 404 (not 403) to avoid leaking existence.

import { NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type { AlertDetail } from "@/lib/types"

export const dynamic = "force-dynamic"
export const revalidate = 0

// Next.js 16 makes params a Promise. Always await it before use.
interface RouteContext {
  params: Promise<{ id: string }>
}

export async function GET(_request: Request, { params }: RouteContext) {
  const { id } = await params

  // Basic input shape check. Real validation (UUID format, etc.) happens
  // on the Brain side against the database schema.
  if (!id || typeof id !== "string" || id.length > 200) {
    return NextResponse.json(
      { error: "not_found", status: 404 },
      { status: 404 },
    )
  }

  // URL-encode in case a future alert id contains anything funky. The
  // Brain endpoint expects /alerts/{id} as a path segment.
  const encoded = encodeURIComponent(id)
  const result = await proxyToBrain<AlertDetail>(`/alerts/${encoded}`)

  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
