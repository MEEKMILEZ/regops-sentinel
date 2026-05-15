import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

import { AuditTable } from "@/components/audit/audit-table"

import { proxyToBrain } from "@/lib/bff"

import type { AuditListResponse } from "@/lib/types"

// Server component. Fetches the audit-log list via the BFF helper
// (same auth path as /alerts: Cognito ID token forwarded to the
// Brain, tenant scoping enforced on the Brain side from the JWT's
// custom:tenant_id claim, S3 prefix derived from that claim).
// Pagination state and rendering live in the AuditTable client
// component.

export const dynamic = "force-dynamic"
export const revalidate = 0

export default async function AuditListPage() {
  const result = await proxyToBrain<AuditListResponse>("/audit?limit=100")

  // Defensive: render an empty table on upstream error rather than
  // throwing. Auth is already gated by middleware.
  const events = result.ok ? result.data.events : []
  const hasMore = result.ok ? result.data.has_more : false

  // Honest header counts, computed from real data. Matches the alerts
  // page convention but with audit-appropriate stats.
  const totalCount = events.length
  const highUrgencyCount = events.filter((e) => e.urgency === "HIGH").length
  const relevantCount = events.filter((e) => e.classification === "RELEVANT")
    .length

  return (
    <div className="flex flex-col gap-6">
      <header>
        <h2 className="text-lg font-semibold">Audit log</h2>
        <p className="text-muted-foreground text-sm">
          {totalCount} events{hasMore ? "+" : ""} · {highUrgencyCount} high
          urgency · {relevantCount} relevant · Acme MedDev
        </p>
      </header>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Immutable classification record</CardTitle>
          <CardDescription className="text-xs">
            One entry per source item processed · stored in S3 with
            customer-managed KMS encryption · sorted newest first · 10 per
            page
          </CardDescription>
        </CardHeader>
        <CardContent>
          <AuditTable events={events} />
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
