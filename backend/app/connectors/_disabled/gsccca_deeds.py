"""GSCCCA connector — Georgia deeds, liens, UCC filings.

Source: https://search.gsccca.org/ (web portal)
"""

from __future__ import annotations

import re
from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_text

GSCCCA_SEARCH = "https://search.gsccca.org/RealEstate/SearchByName.asp"


class GSCCCADeedsConnector(BaseConnector):
    name = "gsccca_deeds"
    description = "GSCCCA — deeds, liens, UCC filings"
    tier = 2
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=0.5, burst_size=2)
    default_confidence = 0.85
    supported_input_types = [EntityType.PERSON, EntityType.BUSINESS]
    supported_output_types = [EntityType.PROPERTY]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        entity_type = entity.get("type", "")
        if entity_type == "PERSON":
            search_name = entity.get("last_name") or entity.get("full_name", "")
        elif entity_type == "BUSINESS":
            search_name = entity.get("name", "")
        else:
            return ConnectorResult(error="Requires PERSON or BUSINESS", source_name=self.name)

        if not search_name or len(search_name.strip()) < 3:
            return ConnectorResult(error="Name too short", source_name=self.name)

        cache_key = {"name": search_name.strip(), "county": "Gwinnett"}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            html = await fetch_text(
                GSCCCA_SEARCH,
                params={"lastname": search_name, "county": "Gwinnett"},
            )
        except Exception as e:
            self.logger.error("GSCCCA error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        entities = []
        relationships = []

        # Extract deed records from HTML
        # Look for instrument types, dates, and parties
        deed_matches = re.findall(
            r'(Deed|Mortgage|Lien|Assignment)[^<]*<[^>]+>\s*(\d{1,2}/\d{1,2}/\d{4})',
            html,
            re.IGNORECASE,
        )

        for instrument_type, date_str in deed_matches[:10]:
            prop_id = str(uuid4())
            entities.append({
                "id": prop_id,
                "type": "PROPERTY",
                "instrument_type": instrument_type.strip(),
                "recording_date": date_str,
                "county": "Gwinnett",
                "state": "GA",
            })

            if entity.get("id"):
                relationships.append({
                    "source_id": entity["id"], "target_id": prop_id,
                    "type": "OWNS_PROPERTY",
                    "properties": {"sources": [self.name], "instrument_type": instrument_type},
                })

        result_data = {"entities": entities, "relationships": relationships}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(
            entities=entities, relationships=relationships,
            raw_data=result_data, source_name=self.name, confidence=self.default_confidence,
        )

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_text(GSCCCA_SEARCH, retries=1)
            return True
        except Exception:
            return False
