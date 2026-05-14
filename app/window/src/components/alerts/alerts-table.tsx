"use client"

import * as React from "react"
import Link from "next/link"
import { ChevronLeft, ChevronRight } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { cn } from "@/lib/utils"

import {
  badgeForAlert,
  formatClassifiedAt,
  humanSource,
  urgencyToneClass,
} from "@/lib/dashboard-stats"

import type { AlertListItem } from "@/lib/types"

interface AlertsTableProps {
  alerts: AlertListItem[]
}

const PAGE_SIZE = 10

// Client-side pagination over an already-fetched array. The server
// component fetches up to limit=50 from the Brain (configured in the
// BFF call) and hands the full set to this component. State lives in
// React; no URL params yet. When/if the dataset grows past 50 rows
// regularly, swap this for server-side ?page= URL pagination.

export function AlertsTable({ alerts }: AlertsTableProps) {
  // Sorted newest-first by classified_at. The Brain returns by alert_id
  // desc which is *usually* the same order, but classified_at is the
  // semantically correct sort here (a backfilled row could land later).
  const sorted = React.useMemo(
    () =>
      [...alerts].sort(
        (a, b) =>
          Date.parse(b.classified_at || "0") -
          Date.parse(a.classified_at || "0"),
      ),
    [alerts],
  )

  const [page, setPage] = React.useState(0)

  const totalPages = Math.max(1, Math.ceil(sorted.length / PAGE_SIZE))
  // Clamp page index in case the dataset shrinks between renders.
  const safePage = Math.min(page, totalPages - 1)
  const startIdx = safePage * PAGE_SIZE
  const endIdx = Math.min(startIdx + PAGE_SIZE, sorted.length)
  const visible = sorted.slice(startIdx, endIdx)

  const canPrev = safePage > 0
  const canNext = safePage < totalPages - 1

  return (
    <div className="flex flex-col gap-3">
      <div className="text-muted-foreground flex items-center justify-between text-xs">
        <span>
          {sorted.length === 0
            ? "No alerts to show"
            : `Showing ${startIdx + 1}–${endIdx} of ${sorted.length}`}
        </span>
        <span>
          Page {safePage + 1} of {totalPages}
        </span>
      </div>

      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-[110px]">External ID</TableHead>
            <TableHead>Title</TableHead>
            <TableHead className="w-[180px]">Source</TableHead>
            <TableHead className="w-[100px]">Urgency</TableHead>
            <TableHead className="w-[150px]">Classification</TableHead>
            <TableHead className="w-[170px]">Classified at</TableHead>
            <TableHead className="w-[40px]"></TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {visible.length === 0 ? (
            <TableRow>
              <TableCell
                colSpan={7}
                className="text-muted-foreground py-8 text-center text-sm"
              >
                No alerts yet. Watchers run on a 30-minute schedule.
              </TableCell>
            </TableRow>
          ) : (
            visible.map((row) => {
              const badge = badgeForAlert(row)
              return (
                <TableRow key={row.alert_id} className="hover:bg-muted/40">
                  <TableCell className="font-mono text-xs">
                    {row.external_id}
                  </TableCell>
                  <TableCell>
                    <Link
                      href={`/alerts/${row.alert_id}`}
                      className="hover:underline"
                    >
                      <span className="line-clamp-1">
                        {row.title || "(untitled)"}
                      </span>
                    </Link>
                  </TableCell>
                  <TableCell className="text-muted-foreground text-sm">
                    {humanSource(row.source)}
                  </TableCell>
                  <TableCell
                    className={cn("text-sm", urgencyToneClass(row.urgency))}
                  >
                    {row.urgency}
                  </TableCell>
                  <TableCell>
                    <Badge variant={badge.variant}>{badge.label}</Badge>
                  </TableCell>
                  <TableCell className="text-muted-foreground font-mono text-xs">
                    {formatClassifiedAt(row.classified_at)}
                  </TableCell>
                  <TableCell>
                    <Link
                      href={`/alerts/${row.alert_id}`}
                      aria-label={`Open alert ${row.external_id}`}
                    >
                      <ChevronRight className="text-muted-foreground size-4" />
                    </Link>
                  </TableCell>
                </TableRow>
              )
            })
          )}
        </TableBody>
      </Table>

      <div className="flex items-center justify-end gap-2 pt-1">
        <Button
          size="sm"
          variant="outline"
          onClick={() => setPage((p) => Math.max(0, p - 1))}
          disabled={!canPrev}
          aria-label="Previous page"
        >
          <ChevronLeft className="size-4" />
          Previous
        </Button>
        <Button
          size="sm"
          variant="outline"
          onClick={() => setPage((p) => Math.min(totalPages - 1, p + 1))}
          disabled={!canNext}
          aria-label="Next page"
        >
          Next
          <ChevronRight className="size-4" />
        </Button>
      </div>
    </div>
  )
}
