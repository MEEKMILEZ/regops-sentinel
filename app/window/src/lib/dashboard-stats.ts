// Pure functions that compute dashboard KPIs and chart data from a list
// of alerts. Kept separate from the page component so the math is easy
// to reason about and (later) unit-test without rendering React.
//
// All computations are based on `classified_at` timestamps from the
// Brain. We never invent numbers; if the upstream data lacks a field,
// the result is honestly zero or null.

import type { AlertListItem } from "@/lib/types"

const DAY_MS = 24 * 60 * 60 * 1000
const WEEK_DAYS = 7

/** A small bucket-per-day series used by sparklines. Length is always
 * WEEK_DAYS, oldest day first. */
export type Sparkline = number[]

export interface DashboardStats {
  total: number
  relevant: number
  highUrgency: number
  notRelevant: number
  needsReview: number
  sparklines: {
    total: Sparkline
    relevant: Sparkline
    highUrgency: Sparkline
    notRelevant: Sparkline
  }
  breakdown: ClassificationBreakdown
  recent: AlertListItem[]
  filterRatePct: number
}

export interface ClassificationBreakdown {
  relevant: number
  notRelevant: number
  needsReview: number
  total: number
}

/** Floor a date to UTC midnight. We bucket by UTC day so the numbers
 * are stable regardless of viewer timezone; the underlying timestamps
 * come from Postgres in UTC. */
function startOfUtcDay(d: Date): Date {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()))
}

/** Build an empty 7-day series ending today (UTC). The oldest day is at
 * index 0, today is at index 6. Returned dates are the midnight bucket
 * boundaries. */
function buildWeekBuckets(now: Date): Date[] {
  const todayStart = startOfUtcDay(now)
  const buckets: Date[] = []
  for (let i = WEEK_DAYS - 1; i >= 0; i--) {
    buckets.push(new Date(todayStart.getTime() - i * DAY_MS))
  }
  return buckets
}

/** Count alerts per UTC day for the last 7 days. Anything older than 7
 * days is dropped from the sparkline (but still counted in totals). */
function countByDay(
  alerts: AlertListItem[],
  predicate: (a: AlertListItem) => boolean,
  buckets: Date[],
): Sparkline {
  const counts = new Array(buckets.length).fill(0) as number[]
  for (const a of alerts) {
    if (!predicate(a)) continue
    const ts = Date.parse(a.classified_at)
    if (Number.isNaN(ts)) continue
    const day = startOfUtcDay(new Date(ts)).getTime()
    const idx = buckets.findIndex((b) => b.getTime() === day)
    if (idx >= 0) counts[idx] += 1
  }
  return counts
}

export function computeDashboardStats(
  alerts: AlertListItem[],
  now: Date = new Date(),
): DashboardStats {
  const buckets = buildWeekBuckets(now)

  const total = alerts.length
  const relevant = alerts.filter((a) => a.classification === "RELEVANT").length
  const notRelevant = alerts.filter(
    (a) => a.classification === "NOT_RELEVANT",
  ).length
  const needsReview = alerts.filter(
    (a) => a.classification === "NEEDS_REVIEW",
  ).length
  const highUrgency = alerts.filter((a) => a.urgency === "HIGH").length

  // Filter rate: how much of the feed the system suppressed as
  // not-relevant. Useful as a "the AI is doing real work" metric.
  const filterRatePct = total > 0 ? Math.round((notRelevant / total) * 100) : 0

  const sparklines = {
    total: countByDay(alerts, () => true, buckets),
    relevant: countByDay(
      alerts,
      (a) => a.classification === "RELEVANT",
      buckets,
    ),
    highUrgency: countByDay(alerts, (a) => a.urgency === "HIGH", buckets),
    notRelevant: countByDay(
      alerts,
      (a) => a.classification === "NOT_RELEVANT",
      buckets,
    ),
  }

  const breakdown: ClassificationBreakdown = {
    relevant,
    notRelevant,
    needsReview,
    total,
  }

  // Most recent first, capped at 5 for the dashboard widget. The full
  // list lives on the alerts page (Stage E.7).
  const recent = [...alerts]
    .sort(
      (a, b) =>
        Date.parse(b.classified_at || "0") -
        Date.parse(a.classified_at || "0"),
    )
    .slice(0, 5)

  return {
    total,
    relevant,
    highUrgency,
    notRelevant,
    needsReview,
    sparklines,
    breakdown,
    recent,
    filterRatePct,
  }
}

/** Convert a Brain source string ("health-canada-recalls") into the
 * human-readable label the existing components expect ("Health Canada
 * Recalls"). Kept here so all source mapping lives in one place. */
export function humanSource(source: string): string {
  switch (source) {
    case "health-canada-recalls":
      return "Health Canada Recalls"
    case "health-canada-medeffect":
      return "MedEffect"
    case "health-canada-shortages":
      return "Health Canada Shortages"
    default:
      return source
  }
}

/** Relative-time string suitable for the recent classifications list.
 * Mirrors the placeholder dataset's `ago` field. */
export function timeAgo(iso: string, now: Date = new Date()): string {
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return ""
  const diffMs = now.getTime() - t
  if (diffMs < 0) return "just now"
  const mins = Math.round(diffMs / 60_000)
  if (mins < 1) return "just now"
  if (mins < 60) return `${mins}m ago`
  const hours = Math.round(mins / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.round(hours / 24)
  return `${days}d ago`
}
