"""GA Secretary of State connector — business registrations.

Source: https://ecorp.sos.ga.gov/BusinessSearch (web scraping, no API)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json, fetch_text

GA_SOS_SEARCH = "https://ecorp.sos.ga.gov/BusinessSearch/search"
GA_SOS_DETAIL = "https://ecorp.sos.ga.gov/BusinessSearch/BusinessInformation"


class GASecretaryStateConnector(BaseConnector):
    name = "ga_secretary_state"
    description = "GA Secretary of State — business registrations"
    tier = 2
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=1.0, burst_size=2)
    default_confidence = 0.85
    supported_input_types = [EntityType.PERSON, EntityType.ADDRESS]
    supported_output_types = [EntityType.BUSINESS, EntityType.PERSON]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        entity_type = entity.get("type", "")
        search_term = ""

        if entity_type == "PERSON":
            search_term = entity.get("full_name") or f"{entity.get('first_name', '')} {entity.get('last_name', '')}"
        elif entity_type == "ADDRESS":
            search_term = entity.get("street", "")

        if not search_term or len(search_term.strip()) < 3:
            return ConnectorResult(error="Search term too short", source_name=self.name)

        cache_key = {"query": search_term.strip(), "state": "GA"}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        # GA SOS has a web form — we'll try to scrape search results
        # Note: This may require session handling / CSRF tokens in production
        try:
            html = await fetch_text(
                GA_SOS_SEARCH,
                params={"SearchType": "name", "SearchTerm": search_term},
            )
        except Exception as e:
            self.logger.error("GA SOS error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        # Parse HTML for business results
        entities = []
        relationships = []
        address_id = entity.get("id")

        # Simple regex-based extraction (production would use BeautifulSoup)
        import re

        # Look for business names and control numbers in the HTML
        # Pattern: control number and business name in table rows
        name_pattern = re.findall(
            r'BusinessInformation\?businessId=(\d+)[^>]*>([^<]+)</a>',
            html,
        )

        for control_num, biz_name in name_pattern[:10]:
            biz_name = biz_name.strip()
            if not biz_name:
                continue

            biz_id = str(uuid4())
            entities.append({
                "id": biz_id,
                "type": "BUSINESS",
                "name": biz_name,
                "legal_name": biz_name,
                "control_number": control_num,
                "state": "GA",
                "registration_url": f"{GA_SOS_DETAIL}?businessId={control_num}",
            })

            if address_id and entity_type == "PERSON":
                relationships.append({
                    "source_id": address_id if entity_type == "ADDRESS" else entity.get("id"),
                    "target_id": biz_id,
                    "type": "OWNS_BUSINESS" if entity_type == "PERSON" else "LOCATED_AT",
                    "properties": {"sources": [self.name]},
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
            await fetch_text(GA_SOS_SEARCH, params={"SearchType": "name", "SearchTerm": "test"}, retries=1)
            return True
        except Exception:
            return False
