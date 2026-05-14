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

/** Shared classification badge mapping. Used by every component that
 * renders an alert summary so HIGH PRIORITY in one place is HIGH
 * PRIORITY everywhere; if the mapping ever needs to change it changes
 * here and everywhere else inherits.
 *
 * Map of (classification, urgency) -> {variant, label}:
 *   - RELEVANT + HIGH    -> destructive "HIGH PRIORITY"
 *   - RELEVANT + other   -> secondary   "REVIEW"
 *   - NEEDS_REVIEW       -> secondary   "NEEDS REVIEW"
 *   - NOT_RELEVANT       -> outline     "FILTERED"
 *   - everything else    -> secondary   (raw classification as label)
 */
export interface BadgeStyle {
  variant: "destructive" | "secondary" | "outline"
  label: string
}

export function badgeForAlert(row: AlertListItem): BadgeStyle {
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

/** Format a UTC ISO timestamp as a "yyyy-mm-dd HH:MM UTC" string for
 * table cells. Stable, sort-friendly, timezone-agnostic. */
export function formatClassifiedAt(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ""
  return d.toISOString().replace("T", " ").slice(0, 16) + " UTC"
}

/** Tone class for urgency text in tables. HIGH is the only urgency the
 * classifier currently emits at the high end; MEDIUM/LOW render muted
 * because they're not action-triggering. */
export function urgencyToneClass(urgency: string): string {
  switch (urgency) {
    case "CRITICAL":
      return "text-red-600 dark:text-red-400 font-medium"
    case "HIGH":
      return "text-red-600 dark:text-red-400 font-medium"
    case "MEDIUM":
      return "text-amber-600 dark:text-amber-400"
    case "LOW":
      return "text-muted-foreground"
    default:
      return "text-muted-foreground"
  }
}

/** Decode the small set of HTML entities that Health Canada's APIs
 * actually emit in description fields ("&nbsp;", "&amp;", etc.). The
 * upstream returns body text with raw HTML entities embedded; we want
 * to render those as plain text without exposing the raw `&nbsp;`
 * strings to a regulatory analyst reading the detail page.
 *
 * Intentionally not a full HTML parser. We only handle the entities
 * we've actually seen in the data; anything else passes through
 * unchanged. That keeps the surface area small and predictable.
 */
const HTML_ENTITIES: Record<string, string> = {
  "&nbsp;": " ",
  "&amp;": "&",
  "&lt;": "<",
  "&gt;": ">",
  "&quot;": '"',
  "&apos;": "'",
  "&#39;": "'",
  "&#34;": '"',
  "&#x27;": "'",
  "&hellip;": "…",
  "&mdash;": "—",
  "&ndash;": "–",
  "&rsquo;": "\u2019",
  "&lsquo;": "\u2018",
  "&rdquo;": "\u201D",
  "&ldquo;": "\u201C",
}

export function cleanBody(input: string | null | undefined): string {
  if (!input) return ""
  let out = input
  for (const [entity, replacement] of Object.entries(HTML_ENTITIES)) {
    out = out.split(entity).join(replacement)
  }
  // Collapse runs of three-or-more newlines down to two so paragraph
  // breaks render cleanly without huge gaps when Health Canada's HTML
  // had a lot of whitespace.
  out = out.replace(/\n{3,}/g, "\n\n")
  return out.trim()
}
