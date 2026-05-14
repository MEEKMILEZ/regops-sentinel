import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

import { AlertsTable } from "@/components/alerts/alerts-table"

import { proxyToBrain } from "@/lib/bff"

import type { AlertsListResponse } from "@/lib/types"

// Server component. Fetches the alerts list via the BFF helper (same
// auth path as the dashboard - Cognito ID token forwarded to the Brain,
// tenant scoping enforced on the Brain side from the JWT's
// custom:tenant_id claim). Pagination state and rendering live in the
// AlertsTable client component below.

export const dynamic = "force-dynamic"
export const revalidate = 0

export default async function AlertsListPage() {
  const result = await proxyToBrain<AlertsListResponse>("/alerts")

  // Defensive: render an empty table on upstream error rather than
  // throwing. Auth is already gated by proxy.ts middleware.
  const alerts = result.ok ? result.data.alerts : []

  // Honest header counts, computed from real data. We don't have any
  // CRITICAL rows in production - the classifier emits HIGH as the top
  // urgency - so we report High urgency instead of Critical.
  const totalCount = alerts.length
  const highUrgencyCount = alerts.filter((a) => a.urgency === "HIGH").length
  const needsReviewCount = alerts.filter(
    (a) => a.classification === "NEEDS_REVIEW",
  ).length

  return (
    <div className="flex flex-col gap-6">
      <header>
        <h2 className="text-lg font-semibold">Alerts</h2>
        <p className="text-muted-foreground text-sm">
          {totalCount} alerts · {highUrgencyCount} high urgency ·{" "}
          {needsReviewCount} needs review · Acme MedDev
        </p>
      </header>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">All classifications</CardTitle>
          <CardDescription className="text-xs">
            All time · sorted by classified_at desc · 10 per page
          </CardDescription>
        </CardHeader>
        <CardContent>
          <AlertsTable alerts={alerts} />
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
