"""
Shortages Watcher
Authenticates against healthproductshortages.ca API
Fetches recently updated shortage and discontinuation reports
Emits normalized items to SQS
Tracks last-seen report IDs in DynamoDB
"""
import json
import os
import urllib.request
import urllib.error
import urllib.parse
import logging
import boto3
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
WATCHER_STATE_TABLE = os.environ["WATCHER_STATE_TABLE"]
WATCHER_NAME = os.environ["WATCHER_NAME"]
HPSC_SECRET_ARN = os.environ["HPSC_SECRET_ARN"]

API_BASE = "https://healthproductshortages.ca/api/v1"
LOGIN_URL = f"{API_BASE}/login"
SEARCH_URL = f"{API_BASE}/search"

sqs = boto3.client("sqs")
dynamodb = boto3.resource("dynamodb")
secrets = boto3.client("secretsmanager")
state_table = dynamodb.Table(WATCHER_STATE_TABLE)


def get_credentials():
    resp = secrets.get_secret_value(SecretId=HPSC_SECRET_ARN)
    return json.loads(resp["SecretString"])


def login(email, password):
    body = urllib.parse.urlencode({"email": email, "password": password}).encode("utf-8")
    req = urllib.request.Request(
        LOGIN_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": "RegOpsSentinel/1.0"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            token = resp.headers.get("auth-token")
            expiry = resp.headers.get("expiry-date")
            if not token:
                raise RuntimeError("Login succeeded but no auth-token header returned")
            return token, expiry
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"Login HTTP {e.code}: {body}")


def search_reports(token, last_id=0):
    params = {
        "orderby": "id",
        "order": "asc"
    }
    if last_id and last_id > 0:
        params["id"] = str(last_id)
    qs = urllib.parse.urlencode(params)
    url = f"{SEARCH_URL}?{qs}"
    logger.info(f"Search URL: {url}")

    req = urllib.request.Request(
        url,
        method="GET",
        headers={
            "auth-token": token,
            "Accept": "application/json",
            "User-Agent": "RegOpsSentinel/1.0"
        }
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="ignore")
        logger.error(f"Search HTTP {e.code}: {body}")
        return None


def get_last_seen_id():
    try:
        resp = state_table.get_item(Key={"watcher_name": WATCHER_NAME})
        return int(resp.get("Item", {}).get("last_seen_max_id", 0))
    except Exception as e:
        logger.warning(f"Could not read last_seen_max_id: {e}")
        return 0


def update_last_seen_id(max_id):
    try:
        state_table.put_item(
            Item={
                "watcher_name": WATCHER_NAME,
                "last_seen_max_id": max_id,
                "last_run_utc": datetime.now(timezone.utc).isoformat()
            }
        )
    except Exception as e:
        logger.error(f"Could not update last_seen_max_id: {e}")


def _safe_dict(value):
    """Return a dict if value is one, otherwise an empty dict.
    HPSC sometimes returns nulls or strings where dicts are expected;
    this keeps normalize() defensive without nested isinstance checks.
    """
    return value if isinstance(value, dict) else {}


def normalize(report):
    """Map a raw HPSC report object to the normalized envelope SQS expects.

    Field map for HPSC shortage records (verified via API inspection on
    May 11 2026; see Phase 4 Stage E.5c notes):

    - en_drug_brand_name -> "APO-ACYCLOVIR - TAB 400MG"      (best title)
    - drug.brand_name    -> "APO-ACYCLOVIR"                  (fallback)
    - en_drug_common_name -> "ACYCLOVIR"                     (last resort)
    - company_name OR drug.company.name -> "APOTEX INC"
    - type is a dict {id, label}; classifier expects label as string
    - shortage_reason is a dict {id, en_reason, ...}
    - tier_3 boolean: critical-impact shortages per Health Canada
      categorisation
    - status: "active" / "resolved" / "anticipated"
    - drug_strength, drug_dosage_form, drug_route: classifier signal
    - actual_start_date / actual_end_date / estimated_end_date: timeline
      context

    Returns the envelope downstream worker.process_message expects, with
    the full original report preserved under `raw` for audit blobs and
    later re-classification (e.g. via the backfill module).
    """
    report_id = report.get("id") or report.get("report_id")

    drug = _safe_dict(report.get("drug"))
    company = _safe_dict(drug.get("company"))
    type_obj = _safe_dict(report.get("type"))
    shortage_reason = _safe_dict(report.get("shortage_reason"))

    # Title prefers the most descriptive HPSC field, falling through to
    # progressively simpler ones if the upstream response is sparse.
    title = (
        report.get("en_drug_brand_name")
        or drug.get("brand_name")
        or report.get("en_drug_common_name")
        or ""
    )

    company_name = report.get("company_name") or company.get("name") or ""

    # Build a summary string from whatever signal is available. The
    # classifier reads this; richer summary text -> better classification.
    summary_parts = []
    if report.get("en_drug_common_name"):
        summary_parts.append(f"Active ingredient: {report['en_drug_common_name']}")
    if report.get("drug_strength"):
        summary_parts.append(f"Strength: {report['drug_strength']}")
    if report.get("drug_dosage_form"):
        summary_parts.append(f"Dosage form: {report['drug_dosage_form']}")
    if report.get("drug_route"):
        summary_parts.append(f"Route: {report['drug_route']}")
    if report.get("status"):
        summary_parts.append(f"Status: {report['status']}")
    if shortage_reason.get("en_reason"):
        summary_parts.append(f"Reason: {shortage_reason['en_reason']}")
    if report.get("tier_3"):
        summary_parts.append("TIER 3 (critical impact)")

    summary = " | ".join(summary_parts)

    return {
        "source": "health-canada-shortages",
        "external_id": str(report_id),
        "title": title,
        "summary": summary,
        # Type label as a string (the classifier prompt expects strings,
        # not the {id, label} dict shape HPSC returns).
        "type": type_obj.get("label", ""),
        "status": report.get("status", ""),
        "tier_3": bool(report.get("tier_3", False)),
        "company_name": company_name,
        "common_name": report.get("en_drug_common_name", ""),
        "strength": report.get("drug_strength", ""),
        "dosage_form": report.get("drug_dosage_form", ""),
        "route": report.get("drug_route", ""),
        "shortage_reason": shortage_reason.get("en_reason", ""),
        "din": report.get("din", ""),
        "actual_start_date": report.get("actual_start_date", ""),
        "actual_end_date": report.get("actual_end_date", ""),
        "estimated_end_date": report.get("estimated_end_date", ""),
        "updated_date": report.get("updated_date", ""),
        "raw": report,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "watcher": WATCHER_NAME
    }


def emit_to_sqs(item):
    sqs.send_message(
        QueueUrl=SQS_QUEUE_URL,
        MessageBody=json.dumps(item),
        MessageAttributes={
            "source": {"DataType": "String", "StringValue": item["source"]},
            "watcher": {"DataType": "String", "StringValue": WATCHER_NAME}
        }
    )


def lambda_handler(event, context):
    logger.info(f"Shortages watcher invoked")

    try:
        creds = get_credentials()
    except Exception as e:
        logger.error(f"Failed to fetch HPSC credentials: {e}")
        return {"status": "error", "error": "credentials_fetch_failed"}

    try:
        token, expiry = login(creds["email"], creds["password"])
        logger.info(f"Authenticated. Token expires: {expiry}")
    except Exception as e:
        logger.error(f"Login failed: {e}")
        return {"status": "error", "error": "login_failed"}

    last_seen_id = get_last_seen_id()
    logger.info(f"Last seen report id: {last_seen_id}")

    result = search_reports(token, last_id=last_seen_id)
    if result is None:
        return {"status": "error", "error": "search_failed"}

    logger.info(f"Search response type: {type(result).__name__}")
    if isinstance(result, dict):
        logger.info(f"Search response keys: {list(result.keys())}")
    elif isinstance(result, list):
        logger.info(f"Search response is list with {len(result)} items")

    reports = []
    if isinstance(result, list):
        reports = result
    elif isinstance(result, dict):
        for candidate_key in ("reports", "data", "results", "items"):
            if candidate_key in result and isinstance(result[candidate_key], list):
                reports = result[candidate_key]
                logger.info(f"Found reports under key: {candidate_key}")
                break
        if not reports:
            for v in result.values():
                if isinstance(v, list):
                    reports = v
                    logger.info(f"Fell back to first list-valued key")
                    break

    if reports:
        logger.info(f"Sample report keys: {list(reports[0].keys()) if isinstance(reports[0], dict) else type(reports[0]).__name__}")

    logger.info(f"Fetched {len(reports)} reports")

    new_max_id = last_seen_id
    emitted = 0
    for report in reports:
        try:
            normalized = normalize(report)
            ext_id = int(normalized["external_id"]) if normalized["external_id"] and normalized["external_id"].isdigit() else 0
            if ext_id > last_seen_id:
                emit_to_sqs(normalized)
                emitted += 1
                if ext_id > new_max_id:
                    new_max_id = ext_id
        except Exception as e:
            logger.error(f"Failed to emit report: {e}")

    if new_max_id > last_seen_id:
        update_last_seen_id(new_max_id)

    logger.info(f"Shortages watcher complete. Emitted {emitted} new reports. New max id: {new_max_id}")
    return {
        "status": "ok",
        "fetched": len(reports),
        "emitted": emitted,
        "new_max_id": new_max_id
    }
