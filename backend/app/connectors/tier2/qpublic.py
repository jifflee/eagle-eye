"""qPublic connector — detailed property records for Gwinnett County.

Source: https://qpublic.schneidercorp.com/ (web scraping)
"""

from __future__ import annotations

import re
from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_text, get_browser_headers

QPUBLIC_SEARCH = "https://qpublic.schneidercorp.com/Application.aspx"
QPUBLIC_APP_ID = "1282"


class QPublicConnector(BaseConnector):
    name = "qpublic"
    description = "qPublic — detailed property records"
    tier = 2
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=0.5, burst_size=2)
    default_confidence = 0.85
    supported_input_types = [EntityType.ADDRESS, EntityType.PERSON]
    supported_output_types = [EntityType.PROPERTY]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        entity_type = entity.get("type", "")
        search_term = ""

        if entity_type == "ADDRESS":
            search_term = entity.get("street", "")
        elif entity_type == "PERSON":
            search_term = entity.get("full_name") or entity.get("last_name", "")

        if not search_term or len(search_term.strip()) < 3:
            return ConnectorResult(error="Search term too short", source_name=self.name)

        cache_key = {"query": search_term.strip()}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            html = await fetch_text(
                QPUBLIC_SEARCH,
                params={"AppID": QPUBLIC_APP_ID, "PageTypeID": "1", "SearchText": search_term},
                headers=get_browser_headers(referer="https://qpublic.schneidercorp.com/"),
            )
        except Exception as e:
            self.logger.error("qPublic error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        entities = []

        # Extract property data from HTML
        # qPublic returns tabular data — extract key fields
        parcel_ids = re.findall(r'Parcel[^"]*["\s]+(\w[\w\-]+\w)', html)
        owners = re.findall(r'Owner[^:]*:\s*([^<\n]+)', html)
        values = re.findall(r'\$[\d,]+(?:\.\d{2})?', html)

        for i, parcel_id in enumerate(parcel_ids[:5]):
            prop_id = str(uuid4())
            entities.append({
                "id": prop_id,
                "type": "PROPERTY",
                "apn": parcel_id.strip(),
                "owner_name": owners[i].strip() if i < len(owners) else "",
                "assessed_value": _parse_currency(values[i]) if i < len(values) else None,
            })

        result_data = {"entities": entities}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(
            entities=entities, raw_data=result_data,
            source_name=self.name, confidence=self.default_confidence,
        )

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_text(
                QPUBLIC_SEARCH,
                params={"AppID": QPUBLIC_APP_ID},
                headers=get_browser_headers(referer="https://qpublic.schneidercorp.com/"),
                retries=1,
            )
            return True
        except Exception:
            return False


def _parse_currency(s: str) -> float | None:
    try:
        return float(s.replace("$", "").replace(",", ""))
    except (ValueError, TypeError):
        return None
