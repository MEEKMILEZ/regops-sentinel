"""Azure OpenAI classifier for regulatory items."""
import json
import logging
from openai import AzureOpenAI
from .config import get_azure_openai_credentials

logger = logging.getLogger(__name__)

_client = None


def get_client():
    global _client
    if _client is None:
        creds = get_azure_openai_credentials()
        _client = AzureOpenAI(
            api_key=creds["api_key"],
            api_version="2024-08-01-preview",
            azure_endpoint=creds["endpoint"]
        )
    return _client


CLASSIFICATION_PROMPT = """You are a regulatory intelligence classifier for Canadian medical device distributors.

Given a regulatory item from Health Canada, classify it according to:

1. classification: one of [RELEVANT, NOT_RELEVANT, NEEDS_REVIEW]
   - RELEVANT: directly affects medical device distributors (recall, advisory, shortage of relevance, regulatory change)
   - NOT_RELEVANT: not applicable to medical device distribution (e.g., consumer product recalls, food)
   - NEEDS_REVIEW: ambiguous, requires human assessment

2. relevance_score: float 0.0 to 1.0 (how relevant for medical device distributors)

3. urgency: one of [CRITICAL, HIGH, MEDIUM, LOW]
   - CRITICAL: immediate distribution halt likely required (Tier 3 shortage, Class I recall)
   - HIGH: significant operational impact (notable recall, major advisory)
   - MEDIUM: relevant but not time-sensitive
   - LOW: background information

4. product_categories: array of broad categories impacted, e.g. ["cardiology-devices", "infusion-pumps", "diagnostic-imaging"]

5. brief_summary: one or two sentences explaining the impact

Respond with strict JSON only, matching this schema:
{
  "classification": "...",
  "relevance_score": 0.0,
  "urgency": "...",
  "product_categories": [],
  "brief_summary": "..."
}
"""


def classify(item: dict, deployment_name: str) -> dict:
    client = get_client()

    user_content = (
        f"Source: {item.get('source')}\n"
        f"Title: {item.get('title')}\n"
        f"Summary: {item.get('summary') or item.get('description', '')}\n"
        f"Status: {item.get('status', '')}\n"
        f"Type: {item.get('type', '')}\n"
        f"URL: {item.get('url', '')}"
    )

    try:
        response = client.chat.completions.create(
            model=deployment_name,
            messages=[
                {"role": "system", "content": CLASSIFICATION_PROMPT},
                {"role": "user", "content": user_content}
            ],
            response_format={"type": "json_object"},
            temperature=0.1,
            max_tokens=500
        )
        result_text = response.choices[0].message.content
        result = json.loads(result_text)
        return result
    except Exception as e:
        logger.error(f"Classification failed: {e}")
        return {
            "classification": "NEEDS_REVIEW",
            "relevance_score": 0.0,
            "urgency": "MEDIUM",
            "product_categories": [],
            "brief_summary": f"Classification error: {str(e)[:200]}"
        }