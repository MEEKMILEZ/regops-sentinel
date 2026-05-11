import Link from "next/link"
import { ChevronRight } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { cn } from "@/lib/utils"

import type { Alert, Classification, Urgency } from "@/lib/placeholder-alerts"
import { getAlerts } from "@/lib/placeholder-alerts"

function classificationBadgeVariant(
  c: Classification,
): "default" | "destructive" | "secondary" | "outline" {
  switch (c) {
    case "RELEVANT":
      return "default"
    case "NEEDS_REVIEW":
      return "secondary"
    case "NOT_RELEVANT":
      return "outline"
  }
}

function classificationLabel(c: Classification): string {
  return c.replace("_", " ")
}

function urgencyToneClass(u: Urgency): string {
  switch (u) {
    case "CRITICAL":
      return "text-red-600 dark:text-red-400 font-medium"
    case "HIGH":
      return "text-amber-600 dark:text-amber-400 font-medium"
    case "MEDIUM":
      return "text-muted-foreground"
    case "LOW":
      return "text-muted-foreground"
  }
}

function formatClassifiedAt(iso: string): string {
  const d = new Date(iso)
  return d.toISOString().replace("T", " ").slice(0, 16) + " UTC"
}

export default function AlertsListPage() {
  const rows: Alert[] = getAlerts()
  const totalCount = rows.length
  const criticalCount = rows.filter((r) => r.urgency === "CRITICAL").length
  const needsReviewCount = rows.filter(
    (r) => r.classification === "NEEDS_REVIEW",
  ).length

  return (
    <div className="flex flex-col gap-6">
      <header>
        <h2 className="text-lg font-semibold">Alerts</h2>
        <p className="text-muted-foreground text-sm">
          {totalCount} alerts · {criticalCount} critical ·{" "}
          {needsReviewCount} pending review · Acme MedDev
        </p>
      </header>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">All classifications</CardTitle>
          <CardDescription className="text-xs">
            Last 7 days · sorted by classified_at desc
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-[110px]">External ID</TableHead>
                <TableHead>Title</TableHead>
                <TableHead className="w-[180px]">Source</TableHead>
                <TableHead className="w-[100px]">Urgency</TableHead>
                <TableHead className="w-[130px]">Classification</TableHead>
                <TableHead className="w-[170px]">Classified at</TableHead>
                <TableHead className="w-[40px]"></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id} className="hover:bg-muted/40">
                  <TableCell className="font-mono text-xs">
                    {row.externalId}
                  </TableCell>
                  <TableCell>
                    <Link
                      href={`/alerts/${row.id}`}
                      className="hover:underline"
                    >
                      <span className="line-clamp-1">{row.title}</span>
                    </Link>
                  </TableCell>
                  <TableCell className="text-muted-foreground text-sm">
                    {row.source}
                  </TableCell>
                  <TableCell
                    className={cn("text-sm", urgencyToneClass(row.urgency))}
                  >
                    {row.urgency}
                  </TableCell>
                  <TableCell>
                    <Badge
                      variant={classificationBadgeVariant(row.classification)}
                    >
                      {classificationLabel(row.classification)}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-muted-foreground font-mono text-xs">
                    {formatClassifiedAt(row.classifiedAt)}
                  </TableCell>
                  <TableCell>
                    <Link
                      href={`/alerts/${row.id}`}
                      aria-label={`Open ${row.externalId}`}
                    >
                      <ChevronRight className="text-muted-foreground size-4" />
                    </Link>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <p className="text-muted-foreground text-center text-xs">
        All values are placeholders until Stage E wires the BFF.
      </p>
    </div>
  )
}
