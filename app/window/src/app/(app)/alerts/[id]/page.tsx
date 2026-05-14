import Link from "next/link"
import { notFound } from "next/navigation"
import { ArrowLeft, ExternalLink } from "lucide-react"

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

import { proxyToBrain } from "@/lib/bff"
import {
  badgeForAlert,
  cleanBody,
  formatClassifiedAt,
  humanSource,
  urgencyToneClass,
} from "@/lib/dashboard-stats"

import type { AlertDetail } from "@/lib/types"

// Server component. Fetches one alert by id from the Brain through the
// BFF helper (same auth path as Stage E.5/E.6/E.7). On not_found, render
// the Next.js 404 page; on any other upstream failure, render an inline
// error banner rather than crashing the route.

export const dynamic = "force-dynamic"
export const revalidate = 0

interface PageProps {
  params: Promise<{ id: string }>
}

export default async function AlertDetailPage({ params }: PageProps) {
  const { id } = await params

  const result = await proxyToBrain<AlertDetail>(
    `/alerts/${encodeURIComponent(id)}`,
  )

  if (!result.ok && result.error.error === "not_found") {
    notFound()
  }

  // For any other error (upstream_unreachable, upstream_error, etc.),
  // surface an inline banner instead of throwing. The page still
  // renders the chrome (sidebar, back link) so the user has a way out.
  if (!result.ok) {
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
        <Card>
          <CardHeader>
            <CardTitle className="text-base">
              Could not load this alert
            </CardTitle>
            <CardDescription className="text-xs">
              The upstream Brain returned an error.
            </CardDescription>
          </CardHeader>
          <CardContent className="text-sm">
            <p className="font-mono">
              {result.error.error}
              {result.error.details ? ` · ${result.error.details}` : ""}
            </p>
          </CardContent>
        </Card>
      </div>
    )
  }

  const alert = result.data

  const badge = badgeForAlert({
    alert_id: alert.alert_id,
    tenant_id: alert.tenant_id,
    source: alert.source,
    external_id: alert.external_id,
    title: alert.title,
    classification: alert.classification,
    urgency: alert.urgency,
    relevance_score: alert.relevance_score,
    product_categories: alert.product_categories,
    classified_at: alert.classified_at,
  })

  // raw_payload is the original watcher envelope; its `summary` is the
  // body text we received from Health Canada (often with HTML entities).
  // The top-level `summary` field on the alert is the classifier's
  // reasoning. Two different things, both useful, displayed in separate
  // cards. cleanBody strips the small set of HTML entities the Health
  // Canada APIs emit so the analyst sees plain text.
  const rawPayload = (alert as AlertDetail & {
    raw_payload?: Record<string, unknown>
  }).raw_payload
  const rawBody =
    rawPayload && typeof rawPayload === "object" && "summary" in rawPayload
      ? String(rawPayload.summary)
      : alert.body ?? ""
  const sourceBody = cleanBody(rawBody)
  const sourceUrl = alert.source_url ?? alert.url ?? ""

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
            {alert.external_id}
          </span>
          <span
            className={cn(
              "rounded-md px-2 py-0.5 text-xs font-medium",
              urgencyToneClass(alert.urgency),
            )}
          >
            {alert.urgency}
          </span>
          <Badge variant={badge.variant}>{badge.label}</Badge>
        </div>
        <h2 className="text-lg font-semibold">
          {alert.title || "(untitled)"}
        </h2>
        <p className="text-muted-foreground text-sm">
          {humanSource(alert.source)} · classified{" "}
          {formatClassifiedAt(alert.classified_at)}
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
            {sourceBody ? (
              <p className="text-sm leading-relaxed whitespace-pre-wrap">
                {sourceBody}
              </p>
            ) : (
              <p className="text-muted-foreground text-sm italic">
                No body text was captured by the watcher for this signal.
              </p>
            )}
            <Separator />
            <div>
              <p className="text-muted-foreground mb-1 text-xs font-medium">
                Source URL
              </p>
              {sourceUrl ? (
                <a
                  href={sourceUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 break-all text-sm hover:underline"
                >
                  {sourceUrl}
                  <ExternalLink className="size-3" />
                </a>
              ) : (
                <p className="text-muted-foreground text-sm italic">
                  No source URL recorded.
                </p>
              )}
            </div>
          </CardContent>
        </Card>

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
              <p className="text-muted-foreground text-xs">Relevance score</p>
              <p className="font-medium tabular-nums">
                {alert.relevance_score === null
                  ? "—"
                  : alert.relevance_score.toFixed(2)}
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
              {!alert.product_categories ||
              alert.product_categories.length === 0 ? (
                <p className="text-muted-foreground italic">none</p>
              ) : (
                <div className="flex flex-wrap gap-1">
                  {alert.product_categories.map((c) => (
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
              {alert.summary ? (
                <p className="text-sm leading-relaxed">{alert.summary}</p>
              ) : (
                <p className="text-muted-foreground text-sm italic">
                  No reasoning recorded for this classification.
                </p>
              )}
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
