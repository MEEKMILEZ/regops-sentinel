"use client"

import * as React from "react"
import { ChevronLeft, ChevronRight, Lock } from "lucide-react"

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
  formatClassifiedAt,
  humanSource,
  urgencyToneClass,
} from "@/lib/dashboard-stats"

import type { AuditEventSummary, Classification, Urgency } from "@/lib/types"

interface AuditTableProps {
  events: AuditEventSummary[]
}

const PAGE_SIZE = 10

// Client-side pagination over an already-fetched array. The server
// component fetches up to limit=100 from the Brain and hands the full
// set to this component. State lives in React; no URL params.
//
// When/if a tenant accumulates more than 100 audit events regularly,
// swap this for cursor-based pagination using the next_cursor field
// the Brain already returns from /audit.

export function AuditTable({ events }: AuditTableProps) {
  // Sorted newest-first by audit_timestamp. The Brain's list is already
  // ordered by S3 LastModified desc within each page, but explicit sort
  // here makes the contract clear and is robust against future changes.
  const sorted = React.useMemo(
    () =>
      [...events].sort(
        (a, b) =>
          Date.parse(b.audit_timestamp || b.last_modified || "0") -
          Date.parse(a.audit_timestamp || a.last_modified || "0"),
      ),
    [events],
  )

  const [page, setPage] = React.useState(0)

  const totalPages = Math.max(1, Math.ceil(sorted.length / PAGE_SIZE))
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
            ? "No audit events to show"
            : `Showing ${startIdx + 1}-${endIdx} of ${sorted.length}`}
        </span>
        <span>
          Page {safePage + 1} of {totalPages}
        </span>
      </div>

      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-[170px]">Recorded at</TableHead>
            <TableHead>Title</TableHead>
            <TableHead className="w-[180px]">Source</TableHead>
            <TableHead className="w-[100px]">External ID</TableHead>
            <TableHead className="w-[100px]">Urgency</TableHead>
            <TableHead className="w-[140px]">Classification</TableHead>
            <TableHead className="w-[80px]">Encrypted</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {visible.length === 0 ? (
            <TableRow>
              <TableCell
                colSpan={7}
                className="text-muted-foreground py-8 text-center text-sm"
              >
                No audit events yet. Events appear here after the Brain
                classifies items from the watchers.
              </TableCell>
            </TableRow>
          ) : (
            visible.map((row) => {
              return (
                <TableRow key={row.audit_id} className="hover:bg-muted/40">
                  <TableCell className="text-muted-foreground font-mono text-xs">
                    {formatClassifiedAt(
                      row.audit_timestamp || row.last_modified,
                    )}
                  </TableCell>
                  <TableCell>
                    <span className="line-clamp-1">
                      {row.title || (
                        <span className="text-muted-foreground italic">
                          (no title)
                        </span>
                      )}
                    </span>
                  </TableCell>
                  <TableCell className="text-muted-foreground text-sm">
                    {humanSource(row.source) || "—"}
                  </TableCell>
                  <TableCell className="font-mono text-xs">
                    {row.external_id || "—"}
                  </TableCell>
                  <TableCell
                    className={cn(
                      "text-sm",
                      urgencyToneClass(row.urgency as Urgency),
                    )}
                  >
                    {row.urgency || "—"}
                  </TableCell>
                  <TableCell>
                    {row.classification ? (
                      <Badge
                        variant={
                          badgeVariantFor(row.classification as Classification)
                        }
                      >
                        {humanClassification(row.classification)}
                      </Badge>
                    ) : (
                      <span className="text-muted-foreground">—</span>
                    )}
                  </TableCell>
                  <TableCell
                    className="text-muted-foreground text-xs"
                    title={
                      row.encryption_key_id
                        ? `KMS key: ${row.encryption_key_id}`
                        : "Encryption key id unavailable"
                    }
                  >
                    <span className="inline-flex items-center gap-1">
                      <Lock className="size-3" />
                      <span className="font-mono">
                        {row.encryption_key_id
                          ? row.encryption_key_id.slice(0, 8)
                          : "—"}
                      </span>
                    </span>
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

// Local helpers - keep them in this file so the audit table is
// self-contained and won't break if the dashboard-stats helpers
// evolve for alerts-specific needs.

function badgeVariantFor(
  classification: Classification,
): "default" | "secondary" | "outline" | "destructive" {
  switch (classification) {
    case "RELEVANT":
      return "default"
    case "NEEDS_REVIEW":
      return "secondary"
    case "NOT_RELEVANT":
      return "outline"
    default:
      return "outline"
  }
}

function humanClassification(c: string): string {
  switch (c) {
    case "RELEVANT":
      return "Relevant"
    case "NEEDS_REVIEW":
      return "Needs review"
    case "NOT_RELEVANT":
      return "Not relevant"
    default:
      return c
  }
}
