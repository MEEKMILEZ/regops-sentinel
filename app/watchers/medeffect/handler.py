"""
MedEffect Watcher
Polls Health Canada MedEffect Advisories and Recalls RSS feed
Emits all advisories to SQS for downstream classification
"""
import json
import os
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
import logging
import boto3
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
WATCHER_STATE_TABLE = os.environ["WATCHER_STATE_TABLE"]
WATCHER_NAME = os.environ["WATCHER_NAME"]

MEDEFFECT_FEED_URL = "https://recalls-rappels.canada.ca/en/feed/health-products-alerts-recalls"

sqs = boto3.client("sqs")
dynamodb = boto3.resource("dynamodb")
state_table = dynamodb.Table(WATCHER_STATE_TABLE)


def get_last_seen():
    try:
        resp = state_table.get_item(Key={"watcher_name": WATCHER_NAME})
        return resp.get("Item", {}).get("last_seen_ids", [])
    except Exception as e:
        logger.warning(f"Could not read last_seen state: {e}")
        return []


def update_last_seen(seen_ids):
    try:
        state_table.put_item(
            Item={
                "watcher_name": WATCHER_NAME,
                "last_seen_ids": seen_ids[:200],
                "last_run_utc": datetime.now(timezone.utc).isoformat()
            }
        )
    except Exception as e:
        logger.error(f"Could not update last_seen state: {e}")


def fetch_feed(url):
    req = urllib.request.Request(url, headers={"User-Agent": "RegOpsSentinel/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def parse_atom_or_rss(xml_bytes):
    items = []
    root = ET.fromstring(xml_bytes)

    ns = {
        "atom": "http://www.w3.org/2005/Atom",
        "dc": "http://purl.org/dc/elements/1.1/"
    }

    if root.tag.endswith("feed"):
        for entry in root.findall("atom:entry", ns):
            title = (entry.findtext("atom:title", default="", namespaces=ns) or "").strip()
            link_el = entry.find("atom:link", ns)
            link = link_el.get("href", "").strip() if link_el is not None else ""
            summary = (entry.findtext("atom:summary", default="", namespaces=ns) or "").strip()
            updated = (entry.findtext("atom:updated", default="", namespaces=ns) or "").strip()
            entry_id = (entry.findtext("atom:id", default=link, namespaces=ns) or "").strip()

            items.append({
                "guid": entry_id,
                "title": title,
                "link": link,
                "description": summary,
                "pub_date": updated
            })
    else:
        for item in root.findall(".//item"):
            title = (item.findtext("title") or "").strip()
            link = (item.findtext("link") or "").strip()
            description = (item.findtext("description") or "").strip()
            pub_date = (item.findtext("pubDate") or "").strip()
            guid = (item.findtext("guid") or link).strip()

            items.append({
                "guid": guid,
                "title": title,
                "link": link,
                "description": description,
                "pub_date": pub_date
            })

    return items


def normalize(item):
    return {
        "source": "health-canada-medeffect",
        "external_id": item["guid"],
        "title": item["title"],
        "url": item["link"],
        "summary": item["description"],
        "published_at": item["pub_date"],
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
    logger.info(f"MedEffect watcher invoked")
    last_seen = set(get_last_seen())

    try:
        xml_bytes = fetch_feed(MEDEFFECT_FEED_URL)
    except urllib.error.URLError as e:
        logger.error(f"Failed to fetch MedEffect feed: {e}")
        return {"status": "error", "error": str(e)}

    items = parse_atom_or_rss(xml_bytes)
    logger.info(f"Parsed {len(items)} items from feed")

    new_items = [i for i in items if i["guid"] not in last_seen]
    logger.info(f"New items: {len(new_items)}")

    emitted = 0
    for item in new_items:
        try:
            normalized = normalize(item)
            emit_to_sqs(normalized)
            emitted += 1
        except Exception as e:
            logger.error(f"Failed to emit {item['guid']}: {e}")

    all_seen_now = list(last_seen | {i["guid"] for i in items})
    update_last_seen(all_seen_now)

    logger.info(f"MedEffect watcher complete. Emitted {emitted} new items.")
    return {
        "status": "ok",
        "feed_items_total": len(items),
        "new_items": len(new_items),
        "emitted": emitted
    }