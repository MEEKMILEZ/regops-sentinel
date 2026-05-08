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


def normalize(report):
    report_id = report.get("id") or report.get("report_id")
    return {
        "source": "health-canada-shortages",
        "external_id": str(report_id),
        "title": report.get("brand_name", ""),
        "company_name": report.get("company_name", ""),
        "status": report.get("status", ""),
        "type": report.get("type", ""),
        "strength": report.get("strength", ""),
        "din": report.get("din", ""),
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