import { KpiCard } from "@/components/dashboard/kpi-card"
import { ObligationsDue } from "@/components/dashboard/obligations-due"
import { RecentClassifications } from "@/components/dashboard/recent-classifications"

// Placeholder sparkline data. Replaced by real time-series in Stage E
// when the BFF returns historical counts.
const sparklines = {
  alertsThisWeek: [12, 9, 15, 18, 14, 22, 24],
  critical: [4, 5, 5, 7, 6, 8, 9],
  obligations: [6, 5, 5, 4, 3, 4, 4],
  auditBlobs: [11, 18, 24, 29, 35, 42, 47],
}

export default function DashboardPage() {
  return (
    <div className="flex flex-col gap-6">
      <header>
        <h2 className="text-lg font-semibold">Welcome back, MEEK</h2>
        <p className="text-muted-foreground text-sm">
          Last sync 4 minutes ago · 3 of 3 watchers running
        </p>
      </header>

      <section
        aria-label="Key performance indicators"
        className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4"
      >
        <KpiCard
          label="Alerts this week"
          value={24}
          trendText="+18%"
          tone="success"
          data={sparklines.alertsThisWeek}
        />
        <KpiCard
          label="Critical"
          value={9}
          trendText="+3 today"
          tone="danger"
          data={sparklines.critical}
        />
        <KpiCard
          label="Obligations due"
          value={4}
          trendText="Soonest 18h"
          tone="warning"
          data={sparklines.obligations}
        />
        <KpiCard
          label="Audit blobs"
          value={47}
          trendText="Immutable · KMS"
          data={sparklines.auditBlobs}
        />
      </section>

      <section className="grid grid-cols-1 gap-3 lg:grid-cols-2">
        <RecentClassifications />
        <ObligationsDue />
      </section>

      <p className="text-muted-foreground text-center text-xs">
        All values are placeholders until Stage E wires the BFF.
      </p>
    </div>
  )
}
