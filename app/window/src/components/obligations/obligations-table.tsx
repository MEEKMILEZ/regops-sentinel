"use client"

import * as React from "react"
import {
  ChevronLeft,
  ChevronRight,
  AlertCircle,
  Clock,
  CheckCircle2,
} from "lucide-react"

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

import type { ObligationListItem } from "@/lib/types"

interface ObligationsTableProps {
  obligations: ObligationListItem[]
}

const PAGE_SIZE = 10

// Client-side pagination over an already-fetched array. Same pattern
// as the alerts, audit, and devices tables. Brain returns ordered by
// status then due_at; we trust that order.

export function ObligationsTable({ obligations }: ObligationsTableProps) {
  const [page, setPage] = React.useState(0)

  const totalPages = Math.max(1, Math.ceil(obligations.length / PAGE_SIZE))
  const safePage = Math.min(page, totalPages - 1)
  const startIdx = safePage * PAGE_SIZE
  const endIdx = Math.min(startIdx + PAGE_SIZE, obligations.length)
  const visible = obligations.slice(startIdx, endIdx)

  const canPrev = safePage > 0
  const canNext = safePage < totalPages - 1

  return (
    <div className="flex flex-col gap-3">
      <div className="text-muted-foreground flex items-center justify-between text-xs">
        <span>
          {obligations.length === 0
            ? "No obligations tracked"
            : `Showing ${startIdx + 1}-${endIdx} of ${obligations.length}`}
        </span>
        <span>
          Page {safePage + 1} of {totalPages}
        </span>
      </div>

      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-[110px]">Status</TableHead>
            <TableHead>Title</TableHead>
            <TableHead className="w-[160px]">Type</TableHead>
            <TableHead className="w-[140px]">Regulator</TableHead>
            <TableHead className="w-[140px]">Due</TableHead>
            <TableHead className="w-[100px]">Severity</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {visible.length === 0 ? (
            <TableRow>
              <TableCell
                colSpan={6}
                className="text-muted-foreground py-8 text-center text-sm"
              >
                No obligations tracked yet. Phase 5C.2 will add create/edit UI.
              </TableCell>
            </TableRow>
          ) : (
            visible.map((row) => {
              const dueRelative = formatDueRelative(row.due_at, row.status)
              return (
                <TableRow key={row.obligation_id} className="hover:bg-muted/40">
                  <TableCell>
                    <span
                      className={cn(
                        "inline-flex items-center gap-1 text-xs font-medium",
                        statusToneClass(row.status),
                      )}
                    >
                      {statusIcon(row.status)}
                      {humanStatus(row.status)}
                    </span>
                  </TableCell>
                  <TableCell>
                    <div className="flex flex-col">
                      <span className="font-medium">{row.title}</span>
                      {row.device_brand_name ? (
                        <span className="text-muted-foreground text-xs">
                          {row.device_brand_name}
                        </span>
                      ) : (
                        <span className="text-muted-foreground text-xs italic">
                          Company-wide
                        </span>
                      )}
                    </div>
                  </TableCell>
                  <TableCell className="text-muted-foreground text-xs">
                    {humanObligationType(row.obligation_type)}
                  </TableCell>
                  <TableCell className="text-muted-foreground text-xs">
                    {humanRegulator(row.regulatory_body)}
                  </TableCell>
                  <TableCell
                    className={cn(
                      "text-xs",
                      dueRelative.tone,
                    )}
                  >
                    {dueRelative.label}
                  </TableCell>
                  <TableCell>
                    <Badge variant={severityVariant(row.severity_if_missed)}>
                      {row.severity_if_missed}
                    </Badge>
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

// --- Display helpers (kept local to the component, self-contained) ----

function statusToneClass(status: string): string {
  switch (status) {
    case "overdue":
      return "text-destructive"
    case "due_soon":
      return "text-amber-600 dark:text-amber-400"
    case "upcoming":
      return "text-foreground"
    case "in_progress":
      return "text-blue-600 dark:text-blue-400"
    case "completed":
      return "text-muted-foreground"
    default:
      return "text-foreground"
  }
}

function statusIcon(status: string): React.ReactNode {
  const cls = "size-3"
  switch (status) {
    case "overdue":
      return <AlertCircle className={cls} />
    case "due_soon":
      return <Clock className={cls} />
    case "completed":
      return <CheckCircle2 className={cls} />
    default:
      return null
  }
}

function humanStatus(status: string): string {
  switch (status) {
    case "overdue":
      return "Overdue"
    case "due_soon":
      return "Due soon"
    case "upcoming":
      return "Upcoming"
    case "in_progress":
      return "In progress"
    case "completed":
      return "Completed"
    case "not_applicable":
      return "N/A"
    default:
      return status
  }
}

function humanObligationType(t: string): string {
  switch (t) {
    case "mdl_renewal":
      return "MDL renewal"
    case "adverse_event_report":
      return "AE report"
    case "recall_notification":
      return "Recall notice"
    case "qms_audit":
      return "QMS audit"
    case "post_market_surveillance":
      return "PMS review"
    case "udi_submission":
      return "UDI submission"
    case "incident_investigation":
      return "RCA / incident"
    default:
      return t.replace(/_/g, " ")
  }
}

function humanRegulator(r: string | null): string {
  if (!r) return "—"
  switch (r) {
    case "health_canada":
      return "Health Canada"
    case "fda":
      return "FDA"
    case "iso_auditor":
      return "ISO 13485 auditor"
    case "internal_qms":
      return "Internal QMS"
    default:
      return r.replace(/_/g, " ")
  }
}

function severityVariant(
  s: string,
): "default" | "secondary" | "outline" | "destructive" {
  switch (s) {
    case "critical":
      return "destructive"
    case "high":
      return "default"
    case "medium":
      return "secondary"
    case "low":
      return "outline"
    default:
      return "outline"
  }
}

function formatDueRelative(
  dueAt: string | null,
  status: string,
): { label: string; tone: string } {
  if (!dueAt) return { label: "—", tone: "text-muted-foreground" }
  if (status === "completed") {
    return { label: formatShortDate(dueAt), tone: "text-muted-foreground" }
  }
  const dueMs = Date.parse(dueAt)
  const nowMs = Date.now()
  const diffMs = dueMs - nowMs
  const diffDays = Math.round(diffMs / (1000 * 60 * 60 * 24))
  if (diffDays < 0) {
    const overdueDays = Math.abs(diffDays)
    return {
      label: `${overdueDays}d overdue`,
      tone: "text-destructive font-medium",
    }
  }
  if (diffDays === 0) return { label: "Today", tone: "text-destructive" }
  if (diffDays <= 7)
    return {
      label: `In ${diffDays}d`,
      tone: "text-amber-600 dark:text-amber-400",
    }
  if (diffDays <= 30) return { label: `In ${diffDays}d`, tone: "text-foreground" }
  return {
    label: formatShortDate(dueAt),
    tone: "text-muted-foreground",
  }
}

function formatShortDate(iso: string): string {
  const d = new Date(iso)
  return d.toLocaleDateString("en-CA", {
    year: "numeric",
    month: "short",
    day: "2-digit",
  })
}
