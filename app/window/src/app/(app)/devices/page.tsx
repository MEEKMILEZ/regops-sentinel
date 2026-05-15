import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

import { DevicesTable } from "@/components/devices/devices-table"
import { UploadFlow } from "@/components/devices/upload-flow"

import { proxyToBrain } from "@/lib/bff"

import type { DevicesListResponse } from "@/lib/types"

// Server component. Fetches the device catalog via the BFF helper
// (same auth path as /alerts and /audit: Cognito ID token forwarded to
// the Brain, tenant scoping enforced upstream from custom:tenant_id).
//
// Phase 5B: read-only catalog view.
// Phase 5B.2: adds CSV upload via the UploadFlow client component.
// Successful uploads trigger router.refresh() so this server component
// re-fetches and the table shows the new rows.

export const dynamic = "force-dynamic"
export const revalidate = 0

export default async function DevicesListPage() {
  const result = await proxyToBrain<DevicesListResponse>("/devices?limit=100")

  // Defensive: render an empty table on upstream error rather than
  // throwing. Auth is already gated by middleware.
  const devices = result.ok ? result.data.devices : []

  // Header KPIs computed from real data. Choices reflect what a
  // compliance lead actually scans for: how many devices, how many
  // recalled (regulatory action open), how many high-class (more
  // regulatory burden).
  const totalCount = devices.length
  const recalledCount = devices.filter((d) => d.status === "recalled").length
  const highClassCount = devices.filter(
    (d) => d.device_class === "III" || d.device_class === "IV",
  ).length

  return (
    <div className="flex flex-col gap-6">
      <header className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-lg font-semibold">Device catalog</h2>
          <p className="text-muted-foreground text-sm">
            {totalCount} devices · {recalledCount} recalled ·{" "}
            {highClassCount} high-class (III/IV) · Acme MedDev
          </p>
        </div>
        <UploadFlow />
      </header>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">
            Distributed medical devices
          </CardTitle>
          <CardDescription className="text-xs">
            UDI-DI · Health Canada MDL where held · grouped by device class
            ascending then brand name · 10 per page
          </CardDescription>
        </CardHeader>
        <CardContent>
          <DevicesTable devices={devices} />
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
