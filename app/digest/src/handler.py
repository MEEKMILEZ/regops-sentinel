"""Weekly regulatory digest Lambda.

Industry-standard pattern: scheduled Lambda invoked by EventBridge cron
rule, queries RDS for the past 7 days of regulatory activity, formats
an HTML+text email, sends via SES.

The handler is deliberately small and procedural - no class hierarchy,
no DI framework. Lambda's billing model and 10-minute max execution
window reward simple flat code over architecture.

Environment variables (set in terraform/environments/dev/lambda-digest.tf):
    DB_SECRET_ARN              ARN of the RDS master secret in Secrets Manager
    DB_HOST                    RDS endpoint hostname
    DB_NAME                    Database name (default: regops)
    DB_PORT                    Database port (default: 5432)
    SES_FROM_ADDRESS           Verified SES sender identity
    SES_REGION                 SES region (matches the rest of the stack)
    DIGEST_RECIPIENTS          Comma-separated list of recipient emails
    DIGEST_TENANT_ID           Tenant whose data to summarise
    LOG_LEVEL                  Logging level (default: INFO)
"""
import json
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
import psycopg
from botocore.exceptions import ClientError
from psycopg.rows import dict_row

# Logging setup. Lambda's container creates a CloudWatch log group
# /aws/lambda/<function-name> automatically; structured log lines
# show up there one per print/logger call.
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


# ---------------------------------------------------------------------
# DB credentials (Secrets Manager)
# ---------------------------------------------------------------------
# Fetched once per cold start and reused across warm invocations. The
# warmup-cache pattern is documented at:
# https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html
# (Lambda keeps the global Python state alive across invocations on
# the same container instance.)
_db_creds_cache = None


def _get_db_credentials() -> dict:
    """Fetch and cache RDS credentials from Secrets Manager."""
    global _db_creds_cache
    if _db_creds_cache is not None:
        return _db_creds_cache

    secret_arn = os.environ["DB_SECRET_ARN"]
    sm = boto3.client("secretsmanager")
    response = sm.get_secret_value(SecretId=secret_arn)
    secret = json.loads(response["SecretString"])

    _db_creds_cache = {
        "host": os.environ.get("DB_HOST") or secret["host"],
        "port": int(os.environ.get("DB_PORT") or secret.get("port", 5432)),
        "dbname": os.environ.get("DB_NAME") or secret.get("dbname", "regops"),
        "username": secret["username"],
        "password": secret["password"],
    }
    return _db_creds_cache


def _db_connect() -> psycopg.Connection:
    """Open a fresh psycopg connection. Lambda VPC networking adds ~50ms
    on cold start; warm invocations reuse the Lambda container but we
    still open a new connection per invocation because the RDS proxy
    pool isn't configured here (would be a Phase 7 polish item)."""
    creds = _get_db_credentials()
    return psycopg.connect(
        host=creds["host"],
        port=creds["port"],
        dbname=creds["dbname"],
        user=creds["username"],
        password=creds["password"],
        sslmode="require",
        row_factory=dict_row,
        connect_timeout=10,
    )


# ---------------------------------------------------------------------
# Data gathering
# ---------------------------------------------------------------------
def _query_summary(tenant_id: str) -> dict:
    """Run the four roll-up queries that feed the digest body.

    Returns a dict with:
      - alert_counts: list of {urgency, classification, count} rows
      - alerts_total: int total alert count in window
      - top_alerts: list of up to 5 most-recent CRITICAL/HIGH alerts
      - upcoming_obligations: list of obligations due in next 14 days
      - overdue_obligations: list of overdue obligations
    """
    cutoff_alerts = datetime.now(timezone.utc) - timedelta(days=7)
    cutoff_obligations = datetime.now(timezone.utc) + timedelta(days=14)

    summary = {
        "tenant_id": tenant_id,
        "window_start": cutoff_alerts.isoformat(),
        "window_end": datetime.now(timezone.utc).isoformat(),
    }

    with _db_connect() as conn:
        with conn.cursor() as cur:
            # ----- Roll-up of alerts by urgency + classification -----
            cur.execute(
                """
                SELECT urgency, classification, COUNT(*) AS count
                FROM alerts
                WHERE tenant_id = %s
                  AND classified_at >= %s
                GROUP BY urgency, classification
                ORDER BY
                    CASE urgency
                        WHEN 'CRITICAL' THEN 1
                        WHEN 'HIGH'     THEN 2
                        WHEN 'MEDIUM'   THEN 3
                        WHEN 'LOW'      THEN 4
                        ELSE 5
                    END,
                    count DESC
                """,
                (tenant_id, cutoff_alerts),
            )
            summary["alert_counts"] = cur.fetchall()
            summary["alerts_total"] = sum(r["count"] for r in summary["alert_counts"])

            # ----- Top CRITICAL / HIGH alerts in the window -----
            cur.execute(
                """
                SELECT alert_id, source, title, urgency,
                       classified_at, url
                FROM alerts
                WHERE tenant_id = %s
                  AND classified_at >= %s
                  AND urgency IN ('CRITICAL', 'HIGH')
                ORDER BY classified_at DESC
                LIMIT 5
                """,
                (tenant_id, cutoff_alerts),
            )
            summary["top_alerts"] = cur.fetchall()

            # ----- Upcoming obligations (next 14 days) -----
            cur.execute(
                """
                SELECT obligation_id, title, obligation_type,
                       status, due_at, severity_if_missed,
                       responsible_party
                FROM obligations
                WHERE tenant_id = %s
                  AND status IN ('upcoming', 'due_soon')
                  AND due_at IS NOT NULL
                  AND due_at <= %s
                ORDER BY due_at ASC
                LIMIT 10
                """,
                (tenant_id, cutoff_obligations),
            )
            summary["upcoming_obligations"] = cur.fetchall()

            # ----- Currently overdue obligations -----
            cur.execute(
                """
                SELECT obligation_id, title, obligation_type,
                       due_at, severity_if_missed, responsible_party
                FROM obligations
                WHERE tenant_id = %s
                  AND status = 'overdue'
                ORDER BY due_at ASC NULLS LAST
                LIMIT 10
                """,
                (tenant_id,),
            )
            summary["overdue_obligations"] = cur.fetchall()

    logger.info(
        "Digest summary computed: alerts=%d critical_high=%d upcoming=%d overdue=%d",
        summary["alerts_total"],
        len(summary["top_alerts"]),
        len(summary["upcoming_obligations"]),
        len(summary["overdue_obligations"]),
    )
    return summary


# ---------------------------------------------------------------------
# Email rendering
# ---------------------------------------------------------------------
def _format_date(dt) -> str:
    if dt is None:
        return "(no date)"
    if isinstance(dt, str):
        return dt
    return dt.strftime("%Y-%m-%d")


def _format_datetime(dt) -> str:
    if dt is None:
        return "(no date)"
    if isinstance(dt, str):
        return dt
    return dt.strftime("%Y-%m-%d %H:%M UTC")


def _render_text(summary: dict) -> str:
    """Plain-text fallback for email clients that don't render HTML.
    SES requires both bodies when sending multipart messages."""
    lines = []
    lines.append("RegOps Sentinel - Weekly Digest")
    lines.append(f"Tenant: {summary['tenant_id']}")
    lines.append(f"Window: {summary['window_start'][:10]} to {summary['window_end'][:10]}")
    lines.append("")

    lines.append(f"ALERTS LAST 7 DAYS: {summary['alerts_total']} total")
    if summary["alert_counts"]:
        for row in summary["alert_counts"]:
            lines.append(
                f"  {row['urgency']:<8} {row['classification']:<15} {row['count']}"
            )
    else:
        lines.append("  (none)")
    lines.append("")

    lines.append("TOP CRITICAL / HIGH ALERTS:")
    if summary["top_alerts"]:
        for a in summary["top_alerts"]:
            lines.append(f"  [{a['urgency']}] {a['title']}")
            lines.append(f"    Source: {a['source']}  Time: {_format_datetime(a['classified_at'])}")
            if a.get("url"):
                lines.append(f"    Link: {a['url']}")
    else:
        lines.append("  (none in window)")
    lines.append("")

    lines.append(f"OVERDUE OBLIGATIONS: {len(summary['overdue_obligations'])}")
    if summary["overdue_obligations"]:
        for o in summary["overdue_obligations"]:
            lines.append(
                f"  [{o['severity_if_missed'].upper()}] {o['title']}  "
                f"(due {_format_date(o['due_at'])}, owner: {o['responsible_party'] or '?'})"
            )
    lines.append("")

    lines.append(f"UPCOMING OBLIGATIONS (next 14 days): {len(summary['upcoming_obligations'])}")
    if summary["upcoming_obligations"]:
        for o in summary["upcoming_obligations"]:
            lines.append(
                f"  {_format_date(o['due_at'])}  [{o['severity_if_missed'].upper()}] {o['title']}"
            )
            lines.append(f"    Type: {o['obligation_type']}  Owner: {o['responsible_party'] or '?'}")
    lines.append("")

    lines.append("--")
    lines.append("RegOps Sentinel - automated weekly digest")
    return "\n".join(lines)


def _render_html(summary: dict) -> str:
    """HTML body. Kept inline (no external CSS, no images) so it renders
    consistently across Outlook, Gmail, Hotmail. Industry standard for
    transactional email is inline styles + table-based layout."""
    urgency_color = {
        "CRITICAL": "#c0392b",
        "HIGH":     "#e67e22",
        "MEDIUM":   "#f1c40f",
        "LOW":      "#27ae60",
    }
    severity_color = {
        "critical": "#c0392b",
        "high":     "#e67e22",
        "medium":   "#f1c40f",
        "low":      "#27ae60",
    }

    def _u_badge(urgency):
        color = urgency_color.get(urgency, "#7f8c8d")
        return (
            f'<span style="background:{color};color:#fff;padding:2px 8px;'
            f'border-radius:3px;font-size:12px;font-weight:bold;">'
            f"{urgency}</span>"
        )

    def _s_badge(sev):
        sev = (sev or "medium").lower()
        color = severity_color.get(sev, "#7f8c8d")
        return (
            f'<span style="background:{color};color:#fff;padding:2px 8px;'
            f'border-radius:3px;font-size:12px;font-weight:bold;">'
            f"{sev.upper()}</span>"
        )

    parts = []
    parts.append('<html><body style="font-family:Segoe UI,Arial,sans-serif;'
                 'max-width:680px;margin:0 auto;padding:24px;color:#2c3e50;">')
    parts.append('<h1 style="color:#2c3e50;border-bottom:2px solid #3498db;'
                 'padding-bottom:8px;">RegOps Sentinel - Weekly Digest</h1>')
    parts.append(f'<p style="color:#7f8c8d;font-size:14px;">'
                 f'Tenant: <code>{summary["tenant_id"]}</code><br>'
                 f'Window: {summary["window_start"][:10]} to {summary["window_end"][:10]}</p>')

    # ----- Alert roll-up -----
    parts.append(f'<h2 style="color:#34495e;">Alerts last 7 days: '
                 f'<span style="color:#3498db;">{summary["alerts_total"]}</span></h2>')
    if summary["alert_counts"]:
        parts.append('<table style="width:100%;border-collapse:collapse;margin-bottom:24px;">')
        parts.append('<thead><tr style="background:#ecf0f1;">'
                     '<th style="text-align:left;padding:8px;">Urgency</th>'
                     '<th style="text-align:left;padding:8px;">Classification</th>'
                     '<th style="text-align:right;padding:8px;">Count</th></tr></thead><tbody>')
        for row in summary["alert_counts"]:
            parts.append('<tr style="border-bottom:1px solid #ecf0f1;">'
                         f'<td style="padding:8px;">{_u_badge(row["urgency"])}</td>'
                         f'<td style="padding:8px;">{row["classification"]}</td>'
                         f'<td style="padding:8px;text-align:right;font-weight:bold;">{row["count"]}</td></tr>')
        parts.append('</tbody></table>')
    else:
        parts.append('<p style="color:#95a5a6;">No alerts ingested in this window.</p>')

    # ----- Top alerts -----
    parts.append('<h2 style="color:#34495e;">Top critical / high alerts</h2>')
    if summary["top_alerts"]:
        for a in summary["top_alerts"]:
            parts.append('<div style="padding:12px;border-left:4px solid '
                         f'{urgency_color.get(a["urgency"], "#7f8c8d")};'
                         'background:#f8f9fa;margin-bottom:8px;">')
            parts.append(f'<div>{_u_badge(a["urgency"])} '
                         f'<strong>{a["title"]}</strong></div>')
            parts.append(f'<div style="font-size:13px;color:#7f8c8d;margin-top:4px;">'
                         f'Source: {a["source"]} | '
                         f'Classified: {_format_datetime(a["classified_at"])}</div>')
            if a.get("url"):
                parts.append(f'<div style="font-size:13px;margin-top:4px;">'
                             f'<a href="{a["url"]}" style="color:#3498db;">View source</a></div>')
            parts.append('</div>')
    else:
        parts.append('<p style="color:#95a5a6;">No critical or high alerts in this window.</p>')

    # ----- Overdue obligations -----
    parts.append(f'<h2 style="color:#c0392b;">Overdue obligations: '
                 f'{len(summary["overdue_obligations"])}</h2>')
    if summary["overdue_obligations"]:
        parts.append('<table style="width:100%;border-collapse:collapse;margin-bottom:24px;">')
        parts.append('<thead><tr style="background:#ecf0f1;">'
                     '<th style="text-align:left;padding:8px;">Severity</th>'
                     '<th style="text-align:left;padding:8px;">Title</th>'
                     '<th style="text-align:left;padding:8px;">Due</th>'
                     '<th style="text-align:left;padding:8px;">Owner</th></tr></thead><tbody>')
        for o in summary["overdue_obligations"]:
            parts.append('<tr style="border-bottom:1px solid #ecf0f1;">'
                         f'<td style="padding:8px;">{_s_badge(o["severity_if_missed"])}</td>'
                         f'<td style="padding:8px;">{o["title"]}</td>'
                         f'<td style="padding:8px;color:#c0392b;">{_format_date(o["due_at"])}</td>'
                         f'<td style="padding:8px;">{o["responsible_party"] or "?"}</td></tr>')
        parts.append('</tbody></table>')
    else:
        parts.append('<p style="color:#27ae60;">No overdue obligations - good standing.</p>')

    # ----- Upcoming obligations -----
    parts.append(f'<h2 style="color:#34495e;">Upcoming obligations (next 14 days): '
                 f'{len(summary["upcoming_obligations"])}</h2>')
    if summary["upcoming_obligations"]:
        parts.append('<table style="width:100%;border-collapse:collapse;margin-bottom:24px;">')
        parts.append('<thead><tr style="background:#ecf0f1;">'
                     '<th style="text-align:left;padding:8px;">Due</th>'
                     '<th style="text-align:left;padding:8px;">Severity</th>'
                     '<th style="text-align:left;padding:8px;">Title</th>'
                     '<th style="text-align:left;padding:8px;">Owner</th></tr></thead><tbody>')
        for o in summary["upcoming_obligations"]:
            parts.append('<tr style="border-bottom:1px solid #ecf0f1;">'
                         f'<td style="padding:8px;">{_format_date(o["due_at"])}</td>'
                         f'<td style="padding:8px;">{_s_badge(o["severity_if_missed"])}</td>'
                         f'<td style="padding:8px;">{o["title"]}</td>'
                         f'<td style="padding:8px;">{o["responsible_party"] or "?"}</td></tr>')
        parts.append('</tbody></table>')
    else:
        parts.append('<p style="color:#95a5a6;">No obligations due in next 14 days.</p>')

    parts.append('<hr style="border:0;border-top:1px solid #ecf0f1;margin:24px 0;">')
    parts.append('<p style="color:#95a5a6;font-size:12px;">'
                 'RegOps Sentinel - automated weekly digest. '
                 'This email was generated by AWS Lambda + SES.</p>')
    parts.append('</body></html>')
    return "".join(parts)


# ---------------------------------------------------------------------
# Email sending
# ---------------------------------------------------------------------
def _send_email(subject: str, html: str, text: str) -> dict:
    """Send via SES SendEmail. Recipients come from the
    DIGEST_RECIPIENTS env var (comma-separated)."""
    recipients = [
        r.strip()
        for r in os.environ["DIGEST_RECIPIENTS"].split(",")
        if r.strip()
    ]
    if not recipients:
        raise ValueError("DIGEST_RECIPIENTS env var is empty")

    sender = os.environ["SES_FROM_ADDRESS"]
    region = os.environ.get("SES_REGION", "ca-central-1")
    ses = boto3.client("ses", region_name=region)

    try:
        response = ses.send_email(
            Source=sender,
            Destination={"ToAddresses": recipients},
            Message={
                "Subject": {"Charset": "UTF-8", "Data": subject},
                "Body": {
                    "Text": {"Charset": "UTF-8", "Data": text},
                    "Html": {"Charset": "UTF-8", "Data": html},
                },
            },
        )
        logger.info("SES send_email succeeded: MessageId=%s recipients=%s",
                    response["MessageId"], recipients)
        return response
    except ClientError as e:
        logger.error("SES send_email failed: %s", e.response["Error"])
        raise


# ---------------------------------------------------------------------
# Lambda entry
# ---------------------------------------------------------------------
def lambda_handler(event, context):
    """EventBridge -> Lambda entry. `event` is the EventBridge schedule
    event payload (unused). `context` provides request_id, function
    name, etc. for log correlation."""
    tenant_id = os.environ.get("DIGEST_TENANT_ID", "tenant-acme-meddev")
    logger.info("Digest run start: tenant=%s request_id=%s",
                tenant_id, getattr(context, "aws_request_id", "local"))

    summary = _query_summary(tenant_id)

    subject = (
        f"RegOps Sentinel weekly digest - "
        f"{summary['alerts_total']} alerts, "
        f"{len(summary['overdue_obligations'])} overdue"
    )
    html_body = _render_html(summary)
    text_body = _render_text(summary)

    result = _send_email(subject, html_body, text_body)

    return {
        "statusCode": 200,
        "tenant_id": tenant_id,
        "alerts_total": summary["alerts_total"],
        "overdue_count": len(summary["overdue_obligations"]),
        "upcoming_count": len(summary["upcoming_obligations"]),
        "ses_message_id": result["MessageId"],
    }
