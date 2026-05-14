import Link from "next/link"

import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

import { humanSource, timeAgo } from "@/lib/dashboard-stats"

import type { AlertListItem } from "@/lib/types"

interface RecentClassificationsProps {
  rows: AlertListItem[]
}

/** Map (classification, urgency) to a badge variant and a short label.
 * The model gives us six combinations across the data we've seen, but
 * we only render the visually distinct cases:
 *   - RELEVANT + HIGH    -> red "HIGH PRIORITY"
 *   - RELEVANT + MEDIUM  -> amber "REVIEW"
 *   - NEEDS_REVIEW       -> amber "NEEDS REVIEW"
 *   - NOT_RELEVANT       -> outline "FILTERED"
 * Everything else falls back to secondary with the raw classification. */
function badgeFor(row: AlertListItem): {
  variant: "destructive" | "secondary" | "outline"
  label: string
} {
  if (row.classification === "RELEVANT" && row.urgency === "HIGH") {
    return { variant: "destructive", label: "HIGH PRIORITY" }
  }
  if (row.classification === "RELEVANT") {
    return { variant: "secondary", label: "REVIEW" }
  }
  if (row.classification === "NEEDS_REVIEW") {
    return { variant: "secondary", label: "NEEDS REVIEW" }
  }
  if (row.classification === "NOT_RELEVANT") {
    return { variant: "outline", label: "FILTERED" }
  }
  return { variant: "secondary", label: row.classification }
}

export function RecentClassifications({ rows }: RecentClassificationsProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Recent classifications</CardTitle>
        <CardDescription className="text-xs">
          Last {rows.length} alerts · Acme MedDev
        </CardDescription>
      </CardHeader>
      <CardContent>
        {rows.length === 0 ? (
          <p className="text-muted-foreground text-sm">
            No alerts yet. Watchers run on a 30-minute schedule.
          </p>
        ) : (
          <ul className="flex flex-col gap-3">
            {rows.map((row) => {
              const badge = badgeFor(row)
              return (
                <li
                  key={row.alert_id}
                  className="flex items-center justify-between gap-3"
                >
                  <div className="min-w-0">
                    <Link
                      href={`/alerts/${row.alert_id}`}
                      className="truncate text-sm hover:underline"
                    >
                      {row.title || "(untitled)"}
                    </Link>
                    <p className="text-muted-foreground text-xs">
                      {humanSource(row.source)} · {timeAgo(row.classified_at)}
                    </p>
                  </div>
                  <Badge variant={badge.variant}>{badge.label}</Badge>
                </li>
              )
            })}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}
