"use client"

import * as React from "react"

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { cn } from "@/lib/utils"

import type { ObligationsListResponse, ObligationListItem } from "@/lib/types"

// Dashboard widget showing the next handful of obligations a compliance
// lead should care about. Fetches from /api/obligations on mount and
// renders the top 4 most-urgent items (Brain already orders by status
// ASC then due_at ASC, so the first 4 ARE the top 4).
//
// Phase 5C wired this to real data. Pre-5C this file held a stub with
// hardcoded rows; the design carried over (left-border urgency stripe,
// countdown on the right, item subtitle muted underneath).

type UrgencyBand = "critical" | "warning" | "routine"

const borderByUrgency: Record<UrgencyBand, string> = {
  critical: "border-l-red-500",
  warning: "border-l-amber-500",
  routine: "border-l-muted-foreground/40",
}

const countdownToneByUrgency: Record<UrgencyBand, string> = {
  critical: "text-red-600 dark:text-red-400",
  warning: "text-amber-600 dark:text-amber-400",
  routine: "text-muted-foreground",
}

const MAX_DISPLAYED = 4

export function ObligationsDue() {
  const [obligations, setObligations] = React.useState<ObligationListItem[]>([])
  const [loading, setLoading] = React.useState(true)
  const [errored, setErrored] = React.useState(false)

  React.useEffect(() => {
    let cancelled = false
    async function load() {
      try {
        const res = await fetch("/api/obligations", { cache: "no-store" })
        if (!res.ok) {
          if (!cancelled) {
            setErrored(true)
            setLoading(false)
          }
          return
        }
        const data: ObligationsListResponse = await res.json()
        if (cancelled) return
        // Brain already orders the list; take the first MAX_DISPLAYED
        // active items (filter out completed which are at the bottom).
        const active = data.obligations.filter(
          (o) => o.status !== "completed" && o.status !== "not_applicable",
        )
        setObligations(active.slice(0, MAX_DISPLAYED))
        setLoading(false)
      } catch {
        if (!cancelled) {
          setErrored(true)
          setLoading(false)
        }
      }
    }
    load()
    return () => {
      cancelled = true
    }
  }, [])

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Obligations due</CardTitle>
        <CardDescription className="text-xs">
          Most-urgent open items · sorted by status then due date
        </CardDescription>
      </CardHeader>
      <CardContent>
        {loading ? (
          <p className="text-muted-foreground text-sm">Loading...</p>
        ) : errored ? (
          <p className="text-muted-foreground text-sm">
            Could not load obligations.
          </p>
        ) : obligations.length === 0 ? (
          <p className="text-muted-foreground text-sm">
            No open obligations. Nice.
          </p>
        ) : (
          <ul className="flex flex-col gap-3">
            {obligations.map((row) => {
              const urgency = urgencyBandFor(row.status, row.due_at)
              const countdown = countdownLabel(row.due_at, row.status)
              const subtitle =
                row.device_brand_name ||
                humanRegulator(row.regulatory_body) ||
                "Company-wide"
              return (
                <li
                  key={row.obligation_id}
                  className={cn("border-l-2 pl-3", borderByUrgency[urgency])}
                >
                  <div className="flex items-baseline justify-between gap-3">
                    <p className="text-sm font-medium">{row.title}</p>
                    <span
                      className={cn(
                        "text-xs font-medium tabular-nums",
                        countdownToneByUrgency[urgency],
                      )}
                    >
                      {countdown}
                    </span>
                  </div>
                  <p className="text-muted-foreground truncate text-xs">
                    {subtitle}
                  </p>
                </li>
              )
            })}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}

// --- Helpers ---------------------------------------------------------

function urgencyBandFor(status: string, dueAt: string | null): UrgencyBand {
  if (status === "overdue") return "critical"
  if (status === "due_soon") return "warning"
  if (!dueAt) return "routine"
  const diffDays = Math.round(
    (Date.parse(dueAt) - Date.now()) / (1000 * 60 * 60 * 24),
  )
  if (diffDays < 0) return "critical"
  if (diffDays <= 7) return "warning"
  return "routine"
}

function countdownLabel(dueAt: string | null, status: string): string {
  if (status === "completed") return "Done"
  if (!dueAt) return "—"
  const diffMs = Date.parse(dueAt) - Date.now()
  const diffDays = Math.round(diffMs / (1000 * 60 * 60 * 24))
  if (diffDays < 0) return `${Math.abs(diffDays)}d late`
  if (diffDays === 0) {
    const diffHours = Math.max(0, Math.round(diffMs / (1000 * 60 * 60)))
    return `${diffHours}h`
  }
  if (diffDays === 1) {
    const remHours = Math.max(
      0,
      Math.round((diffMs - 24 * 60 * 60 * 1000) / (1000 * 60 * 60)),
    )
    return `1d ${remHours}h`
  }
  return `${diffDays}d`
}

function humanRegulator(r: string | null): string {
  if (!r) return ""
  switch (r) {
    case "health_canada":
      return "Health Canada"
    case "fda":
      return "FDA"
    case "iso_auditor":
      return "ISO 13485 audit"
    case "internal_qms":
      return "Internal QMS"
    default:
      return r.replace(/_/g, " ")
  }
}
