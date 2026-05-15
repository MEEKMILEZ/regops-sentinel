"use client"

import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts"

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

import type { ClassificationBreakdown } from "@/lib/dashboard-stats"

interface ClassificationBreakdownChartProps {
  data: ClassificationBreakdown
}

// Recharts is a client-side library (uses SVG measurement, hooks, etc.),
// so this component is marked "use client". The parent dashboard page
// stays a server component; it computes the breakdown numbers and passes
// them down as a plain object.

// Semantic colours. The base shadcn theme is deliberately monochromatic
// (--chart-1..5 are all shades of grey), which keeps cards and sparklines
// clean. But for *classification* breakdowns we want the colour to mean
// something: green = real signal, amber = ambiguous, neutral grey =
// filtered noise. Hardcoded oklch values so the chart never depends on
// theme drift elsewhere.
const COLORS = {
  relevant: "oklch(0.65 0.17 162)", // emerald-ish green
  needsReview: "oklch(0.78 0.15 84)", // amber
  notRelevant: "oklch(0.65 0 0)", // neutral mid-grey
} as const

export function ClassificationBreakdownChart({
  data,
}: ClassificationBreakdownChartProps) {
  // Build the slice list, filtering out zero slices so the chart doesn't
  // render empty wedges.
  const slices = [
    {
      key: "relevant",
      label: "Relevant",
      value: data.relevant,
      fill: COLORS.relevant,
    },
    {
      key: "needsReview",
      label: "Needs review",
      value: data.needsReview,
      fill: COLORS.needsReview,
    },
    {
      key: "notRelevant",
      label: "Filtered",
      value: data.notRelevant,
      fill: COLORS.notRelevant,
    },
  ].filter((s) => s.value > 0)

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Classification breakdown</CardTitle>
        <CardDescription className="text-xs">
          {data.total} alerts · all time
        </CardDescription>
      </CardHeader>
      <CardContent>
        {data.total === 0 ? (
          <p className="text-muted-foreground text-sm">
            No alerts to classify yet.
          </p>
        ) : (
          <div className="flex flex-col gap-4 sm:flex-row sm:items-center">
            <div className="h-40 w-full sm:w-1/2">
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie
                    data={slices}
                    dataKey="value"
                    nameKey="label"
                    cx="50%"
                    cy="50%"
                    innerRadius="55%"
                    outerRadius="90%"
                    paddingAngle={2}
                    stroke="var(--background)"
                  >
                    {slices.map((s) => (
                      <Cell key={s.key} fill={s.fill} />
                    ))}
                  </Pie>
                  <Tooltip
                    contentStyle={{
                      background: "var(--popover)",
                      border: "1px solid var(--border)",
                      borderRadius: "0.5rem",
                      fontSize: "0.75rem",
                    }}
                    formatter={(value, name) => [
                      `${value ?? 0} alerts`,
                      String(name),
                    ]}
                  />
                </PieChart>
              </ResponsiveContainer>
            </div>
            <ul className="flex flex-col gap-2 text-sm sm:w-1/2">
              {slices.map((s) => {
                const pct = Math.round((s.value / data.total) * 100)
                return (
                  <li
                    key={s.key}
                    className="flex items-center justify-between gap-3"
                  >
                    <span className="flex items-center gap-2">
                      <span
                        aria-hidden
                        className="inline-block h-3 w-3 rounded-sm"
                        style={{ background: s.fill }}
                      />
                      {s.label}
                    </span>
                    <span className="text-muted-foreground tabular-nums">
                      {s.value} · {pct}%
                    </span>
                  </li>
                )
              })}
            </ul>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
