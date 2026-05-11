import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

interface ClassificationRow {
  id: string
  title: string
  source: string
  ago: string
  classification: "CRITICAL" | "NEEDS_REVIEW" | "NOT_RELEVANT"
}

// Placeholder dataset. Replaced by a fetch through the BFF in Stage E.
const rows: ClassificationRow[] = [
  {
    id: "rec-82041",
    title: "Class I recall — cardiac stent migration",
    source: "Health Canada Recalls",
    ago: "2h ago",
    classification: "CRITICAL",
  },
  {
    id: "rec-82042",
    title: "Insulin Glargine drug shortage",
    source: "Health Canada Shortages",
    ago: "4h ago",
    classification: "CRITICAL",
  },
  {
    id: "rec-82045",
    title: "Acetaminophen hepatotoxicity report",
    source: "MedEffect",
    ago: "6h ago",
    classification: "NOT_RELEVANT",
  },
  {
    id: "rec-82048",
    title: "Surgical mesh defect — voluntary recall",
    source: "Health Canada Recalls",
    ago: "8h ago",
    classification: "NEEDS_REVIEW",
  },
]

function badgeVariantFor(
  classification: ClassificationRow["classification"],
): "destructive" | "secondary" | "outline" {
  switch (classification) {
    case "CRITICAL":
      return "destructive"
    case "NEEDS_REVIEW":
      return "secondary"
    case "NOT_RELEVANT":
      return "outline"
  }
}

function labelFor(
  classification: ClassificationRow["classification"],
): string {
  return classification.replace("_", " ")
}

export function RecentClassifications() {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Recent classifications</CardTitle>
        <CardDescription className="text-xs">
          Last 24 hours · Acme MedDev
        </CardDescription>
      </CardHeader>
      <CardContent>
        <ul className="flex flex-col gap-3">
          {rows.map((row) => (
            <li
              key={row.id}
              className="flex items-center justify-between gap-3"
            >
              <div className="min-w-0">
                <p className="truncate text-sm">{row.title}</p>
                <p className="text-muted-foreground text-xs">
                  {row.source} · {row.ago}
                </p>
              </div>
              <Badge variant={badgeVariantFor(row.classification)}>
                {labelFor(row.classification)}
              </Badge>
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  )
}
