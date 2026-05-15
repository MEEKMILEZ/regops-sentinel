import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

import { ObligationsTable } from "@/components/obligations/obligations-table"

import { proxyToBrain } from "@/lib/bff"

import type { ObligationsListResponse } from "@/lib/types"

// Server component. Fetches the obligations list via the BFF helper.
// Same auth + tenant-scoping pattern as /alerts, /audit, /devices.

export const dynamic = "force-dynamic"
export const revalidate = 0

export default async function ObligationsListPage() {
  const result =
    await proxyToBrain<ObligationsListResponse>("/obligations?limit=100")

  const obligations = result.ok ? result.data.obligations : []

  // KPIs that match how a compliance lead scans:
  // overdue (action needed now), due_soon (action needed this week),
  // upcoming (visible pipeline).
  const overdueCount = obligations.filter((o) => o.status === "overdue").length
  const dueSoonCount = obligations.filter((o) => o.status === "due_soon").length
  const upcomingCount = obligations.filter((o) => o.status === "upcoming").length

  return (
    <div className="flex flex-col gap-6">
      <header>
        <h2 className="text-lg font-semibold">Regulatory obligations</h2>
        <p className="text-muted-foreground text-sm">
          {overdueCount} overdue · {dueSoonCount} due soon · {upcomingCount}{" "}
          upcoming · Acme MedDev
        </p>
      </header>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Compliance obligations</CardTitle>
          <CardDescription className="text-xs">
            Health Canada CMDR Section 60 · ISO 13485 QMS · FDA UDI cycles
            · grouped by urgency status then due date · 10 per page
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ObligationsTable obligations={obligations} />
        </CardContent>
      </Card>

      {!result.ok ? (
        <p className="text-muted-foreground text-center text-xs">
          Data fetch failed: {result.error.error}
          {result.error.details ? ` (${result.error.details})` : ""}
        </p>
      ) : null}
    </div>
  )
}
