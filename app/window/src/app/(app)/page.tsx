import { KpiCard } from "@/components/dashboard/kpi-card"
import { ClassificationBreakdownChart } from "@/components/dashboard/classification-breakdown"
import { RecentClassifications } from "@/components/dashboard/recent-classifications"

import {
  proxyToBrain,
  getCurrentUserClaims,
  formatTenantDisplay,
} from "@/lib/bff"
import { computeDashboardStats } from "@/lib/dashboard-stats"

import type { AlertsListResponse } from "@/lib/types"

// Dashboard fetches real alert data server-side via the BFF helper.
// We bypass the HTTP layer (no fetch to /api/alerts) and call
// proxyToBrain directly: same auth (cookie -> Cognito ID token), same
// upstream (Brain ALB), but no localhost round-trip. The HTTP route at
// /api/alerts still exists for client-side fetches in the alerts list
// and detail pages (Stage E.7 / E.8).

export const dynamic = "force-dynamic"
export const revalidate = 0

export default async function DashboardPage() {
  // Fetch the user's identity claims and tenant-scoped alerts in
  // parallel. Both originate from the same Cognito session cookie.
  const [claims, result] = await Promise.all([
    getCurrentUserClaims(),
    proxyToBrain<AlertsListResponse>("/alerts"),
  ])

  // Derive display strings from the verified ID token. The Brain
  // enforces tenant scoping from the same claim; the UI just reflects
  // what the user is already authorized to see.
  const displayName = claims?.name?.split(" ")[0].toUpperCase() ?? "there"
  const tenantDisplay = claims ? formatTenantDisplay(claims.tenantId) : ""

  // Defensive: if the BFF helper failed, render an empty dashboard
  // rather than crashing the page. Auth gating already happened in the
  // proxy.ts middleware, so an error here is an upstream/server issue.
  const alerts = result.ok ? result.data.alerts : []
  const stats = computeDashboardStats(alerts)

  return (
    <div className="flex flex-col gap-6">
      <header>
        <h2 className="text-lg font-semibold">Welcome back, {displayName}</h2>
        <p className="text-muted-foreground text-sm">
          Acme MedDev · 3 of 3 watchers running on a 30-minute schedule
        </p>
      </header>

      <section
        aria-label="Key performance indicators"
        className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4"
      >
        <KpiCard
          label="Total alerts"
          value={stats.total}
          trendText="Across 3 watchers"
          data={stats.sparklines.total}
        />
        <KpiCard
          label="Relevant"
          value={stats.relevant}
          trendText="Requires distribution review"
          tone="success"
          data={stats.sparklines.relevant}
        />
        <KpiCard
          label="High urgency"
          value={stats.highUrgency}
          trendText="24h response window"
          tone="danger"
          data={stats.sparklines.highUrgency}
        />
        <KpiCard
          label="Filtered noise"
          value={stats.notRelevant}
          trendText={`AI-filtered · ${stats.filterRatePct}% of feed`}
          data={stats.sparklines.notRelevant}
        />
      </section>

      <section className="grid grid-cols-1 gap-3 lg:grid-cols-2">
        <RecentClassifications rows={stats.recent} />
        <ClassificationBreakdownChart data={stats.breakdown} />
      </section>

      {!result.ok ? (
        <p className="text-muted-foreground text-center text-xs">
          Data fetch failed: {result.error.error}
          {result.error.details ? ` (${result.error.details})` : ""}
        </p>
      ) : null}
    </div>
  )
}
