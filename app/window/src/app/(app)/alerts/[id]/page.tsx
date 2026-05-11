import Link from "next/link"
import { notFound } from "next/navigation"
import { ArrowLeft, ExternalLink, ShieldCheck } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Separator } from "@/components/ui/separator"
import { cn } from "@/lib/utils"

import type { Classification, Urgency } from "@/lib/placeholder-alerts"
import { getAlertById } from "@/lib/placeholder-alerts"

function classificationBadgeVariant(
  c: Classification,
): "default" | "destructive" | "secondary" | "outline" {
  switch (c) {
    case "RELEVANT":
      return "default"
    case "NEEDS_REVIEW":
      return "secondary"
    case "NOT_RELEVANT":
      return "outline"
  }
}

function urgencyToneClass(u: Urgency): string {
  switch (u) {
    case "CRITICAL":
      return "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300"
    case "HIGH":
      return "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300"
    case "MEDIUM":
      return "bg-muted text-muted-foreground"
    case "LOW":
      return "bg-muted text-muted-foreground"
  }
}

function formatClassifiedAt(iso: string): string {
  const d = new Date(iso)
  return d.toISOString().replace("T", " ").slice(0, 19) + " UTC"
}

interface PageProps {
  params: Promise<{ id: string }>
}

export default async function AlertDetailPage({ params }: PageProps) {
  const { id } = await params
  const alert = getAlertById(id)
  if (!alert) {
    notFound()
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <Link
          href="/alerts"
          className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1 text-sm"
        >
          <ArrowLeft className="size-3.5" />
          Back to alerts
        </Link>
      </div>

      <header className="flex flex-col gap-2">
        <div className="flex items-center gap-2">
          <span className="text-muted-foreground font-mono text-xs">
            {alert.externalId}
          </span>
          <span
            className={cn(
              "rounded-md px-2 py-0.5 text-xs font-medium",
              urgencyToneClass(alert.urgency),
            )}
          >
            {alert.urgency}
          </span>
          <Badge variant={classificationBadgeVariant(alert.classification)}>
            {alert.classification.replace("_", " ")}
          </Badge>
        </div>
        <h2 className="text-lg font-semibold">{alert.title}</h2>
        <p className="text-muted-foreground text-sm">
          {alert.source} · {alert.ago} · classified{" "}
          {formatClassifiedAt(alert.classifiedAt)}
        </p>
      </header>

      <div className="grid grid-cols-1 gap-3 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader>
            <CardTitle className="text-base">Signal content</CardTitle>
            <CardDescription className="text-xs">
              Raw body received from the source watcher
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-col gap-4">
            <p className="text-sm leading-relaxed">{alert.body}</p>
            <Separator />
            <div>
              <p className="text-muted-foreground mb-1 text-xs font-medium">
                Source URL
              </p>
              <a
                href={alert.sourceUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 break-all text-sm hover:underline"
              >
                {alert.sourceUrl}
                <ExternalLink className="size-3" />
              </a>
            </div>
          </CardContent>
        </Card>

        <div className="flex flex-col gap-3">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Classifier output</CardTitle>
              <CardDescription className="text-xs">
                Azure OpenAI gpt-4o-regops · single-pass
              </CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-3 text-sm">
              <div>
                <p className="text-muted-foreground text-xs">Classification</p>
                <p className="font-medium">
                  {alert.classification.replace("_", " ")}
                </p>
              </div>
              <div>
                <p className="text-muted-foreground text-xs">Confidence</p>
                <p className="font-medium tabular-nums">
                  {alert.confidence.toFixed(2)}
                </p>
              </div>
              <div>
                <p className="text-muted-foreground text-xs">Urgency</p>
                <p className="font-medium">{alert.urgency}</p>
              </div>
              <div>
                <p className="text-muted-foreground text-xs">
                  Product categories
                </p>
                {alert.categories.length === 0 ? (
                  <p className="text-muted-foreground italic">none</p>
                ) : (
                  <div className="flex flex-wrap gap-1">
                    {alert.categories.map((c) => (
                      <Badge key={c} variant="outline" className="font-mono">
                        {c}
                      </Badge>
                    ))}
                  </div>
                )}
              </div>
              <Separator />
              <div>
                <p className="text-muted-foreground mb-1 text-xs">Reasoning</p>
                <p className="text-sm leading-relaxed">{alert.reasoning}</p>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2 text-base">
                <ShieldCheck className="size-4" />
                Audit record
              </CardTitle>
              <CardDescription className="text-xs">
                Immutable, KMS-encrypted, tenant-scoped prefix
              </CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-2 text-xs">
              <div>
                <p className="text-muted-foreground">Storage path</p>
                <p className="break-all font-mono">{alert.auditPath}</p>
              </div>
              <div>
                <p className="text-muted-foreground">S3 Version ID</p>
                <p className="font-mono">{alert.auditVersionId}</p>
              </div>
              <div>
                <p className="text-muted-foreground">KMS key alias</p>
                <p className="font-mono">{alert.kmsKeyAlias}</p>
              </div>
            </CardContent>
          </Card>
        </div>
      </div>

      <p className="text-muted-foreground text-center text-xs">
        All values are placeholders until Stage E wires the BFF.
      </p>
    </div>
  )
}
