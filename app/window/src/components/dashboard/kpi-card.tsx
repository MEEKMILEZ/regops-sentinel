"use client"

import * as React from "react"
import { LineChart, Line, ResponsiveContainer } from "recharts"

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { cn } from "@/lib/utils"

type Tone = "default" | "danger" | "warning" | "success"

const valueToneClass: Record<Tone, string> = {
  default: "",
  danger: "text-red-600 dark:text-red-400",
  warning: "text-amber-600 dark:text-amber-400",
  success: "text-emerald-600 dark:text-emerald-400",
}

const trendToneClass: Record<Tone, string> = {
  default: "text-muted-foreground",
  danger: "text-red-600 dark:text-red-400",
  warning: "text-amber-600 dark:text-amber-400",
  success: "text-emerald-600 dark:text-emerald-400",
}

const sparkStrokeByTone: Record<Tone, string> = {
  default: "var(--muted-foreground)",
  danger: "#dc2626",
  warning: "#d97706",
  success: "#059669",
}

export interface KpiCardProps {
  label: string
  value: string | number
  trendText: string
  tone?: Tone
  data: number[]
}

export function KpiCard({
  label,
  value,
  trendText,
  tone = "default",
  data,
}: KpiCardProps) {
  const chartData = data.map((y, i) => ({ x: i, y }))

  return (
    <Card>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between gap-2">
          <CardDescription className="text-xs">{label}</CardDescription>
          <span className={cn("text-xs", trendToneClass[tone])}>
            {trendText}
          </span>
        </div>
        <CardTitle
          className={cn(
            "text-2xl font-semibold tabular-nums",
            valueToneClass[tone],
          )}
        >
          {value}
        </CardTitle>
      </CardHeader>
      <CardContent className="pt-0">
        <div className="h-6 w-full">
          <ResponsiveContainer width="100%" height="100%">
            <LineChart
              data={chartData}
              margin={{ top: 2, right: 0, bottom: 2, left: 0 }}
            >
              <Line
                type="monotone"
                dataKey="y"
                stroke={sparkStrokeByTone[tone]}
                strokeWidth={1.5}
                dot={false}
                isAnimationActive={false}
              />
            </LineChart>
          </ResponsiveContainer>
        </div>
      </CardContent>
    </Card>
  )
}
