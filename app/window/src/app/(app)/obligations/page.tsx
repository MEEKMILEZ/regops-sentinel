import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

import { ObligationsPageClient } from "@/components/obligations/obligations-page-client"

import { proxyToBrain } from "@/lib/bff"

import type { ObligationsListResponse } from "@/lib/types"

// Server component. Fetches the obligations list via the BFF helper.
// Same auth + tenant-scoping pattern as /alerts, /audit, /devices.
// Interactive bits (New button, form dialog state) live in the client
// wrapper ObligationsPageClient.

export const dynamic = "force-dynamic"
export const revalidate = 0

export default async function ObligationsListPage() {
  const result =
    await proxyToBrain<ObligationsListResponse>("/obligations?limit=100")

  const obligations = result.ok ? result.data.obligations : []

  const overdueCount = obligations.filter((o) => o.status === "overdue").length
  const dueSoonCount = obligations.filter((o) => o.status === "due_soon").length
  const upcomingCount = obligations.filter((o) => o.status === "upcoming").length

  return (
    <div className="flex flex-col gap-6">
      <header>
        <h2 className="text-lg font-semibold">Regulatory obligations</h2>
        <p className="text-muted-foreground text-sm">
          {overdueCount} overdue &middot; {dueSoonCount} due soon &middot;{" "}
          {upcomingCount} upcoming &middot; Acme MedDev
        </p>
      </header>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Compliance obligations</CardTitle>
          <CardDescription className="text-xs">
            Health Canada CMDR Section 60 &middot; ISO 13485 QMS &middot; FDA UDI
            cycles &middot; grouped by urgency status then due date &middot; 10
            per page
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <ObligationsPageClient obligations={obligations} />
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