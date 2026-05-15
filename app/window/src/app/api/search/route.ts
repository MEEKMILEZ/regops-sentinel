// BFF: GET /api/search?q=...
// Forwards the search query to the Brain along with the user's JWT.
// Brain enforces tenant scoping; this proxy is a thin pass-through.

import { NextRequest, NextResponse } from "next/server"

import { proxyToBrain } from "@/lib/bff"
import type { SearchResponse } from "@/lib/types"

export const dynamic = "force-dynamic"
export const revalidate = 0

export async function GET(request: NextRequest) {
  const q = request.nextUrl.searchParams.get("q") ?? ""
  // Empty query short-circuits without hitting the Brain.
  if (!q.trim()) {
    return NextResponse.json(
      { query: "", count: 0, results: [] } satisfies SearchResponse,
      { status: 200 },
    )
  }
  const encoded = encodeURIComponent(q)
  const result = await proxyToBrain<SearchResponse>(
    `/search?q=${encoded}&limit=10`,
  )
  if (!result.ok) {
    return NextResponse.json(result.error, { status: result.error.status })
  }
  return NextResponse.json(result.data, { status: result.status })
}
