import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { cn } from "@/lib/utils"

type Urgency = "critical" | "warning" | "routine"

interface ObligationRow {
  id: string
  title: string
  subtitle: string
  countdown: string
  urgency: Urgency
}

const rows: ObligationRow[] = [
  {
    id: "ob-1",
    title: "Report to Health Canada",
    subtitle: "Cardiac stent recall · Class I",
    countdown: "18h",
    urgency: "critical",
  },
  {
    id: "ob-2",
    title: "Notify customers",
    subtitle: "Insulin Glargine shortage",
    countdown: "1d 4h",
    urgency: "critical",
  },
  {
    id: "ob-3",
    title: "Update product catalog",
    subtitle: "Surgical mesh recall · Class II",
    countdown: "3d",
    urgency: "warning",
  },
  {
    id: "ob-4",
    title: "File quarterly attestation",
    subtitle: "Q1 PHIPA compliance",
    countdown: "6d",
    urgency: "routine",
  },
]

const borderByUrgency: Record<Urgency, string> = {
  critical: "border-l-red-500",
  warning: "border-l-amber-500",
  routine: "border-l-muted-foreground/40",
}

const countdownToneByUrgency: Record<Urgency, string> = {
  critical: "text-red-600 dark:text-red-400",
  warning: "text-amber-600 dark:text-amber-400",
  routine: "text-muted-foreground",
}

export function ObligationsDue() {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Obligations due</CardTitle>
        <CardDescription className="text-xs">
          Within 7 days · sorted by urgency
        </CardDescription>
      </CardHeader>
      <CardContent>
        <ul className="flex flex-col gap-3">
          {rows.map((row) => (
            <li
              key={row.id}
              className={cn("border-l-2 pl-3", borderByUrgency[row.urgency])}
            >
              <div className="flex items-baseline justify-between gap-3">
                <p className="text-sm font-medium">{row.title}</p>
                <span
                  className={cn(
                    "text-xs font-medium tabular-nums",
                    countdownToneByUrgency[row.urgency],
                  )}
                >
                  {row.countdown}
                </span>
              </div>
              <p className="text-muted-foreground truncate text-xs">
                {row.subtitle}
              </p>
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  )
}
