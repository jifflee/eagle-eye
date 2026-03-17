"""OpenCorporates connector — global company registry.

API: https://api.opencorporates.com/ (free for open data projects)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

OC_API_BASE = "https://api.opencorporates.com/v0.4"


class OpenCorporatesConnector(BaseConnector):
    name = "opencorporates"
    description = "OpenCorporates — global company registry"
    tier = 3
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=1.0, burst_size=3)
    default_confidence = 0.80
    supported_input_types = [EntityType.PERSON, EntityType.BUSINESS]
    supported_output_types = [EntityType.BUSINESS, EntityType.PERSON]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        entity_type = entity.get("type", "")
        if entity_type == "PERSON":
            return await self._search_officers(entity)
        elif entity_type == "BUSINESS":
            return await self._search_companies(entity)
        return ConnectorResult(error="Requires PERSON or BUSINESS", source_name=self.name)

    async def _search_companies(self, entity: dict[str, Any]) -> ConnectorResult:
        name = entity.get("name", "")
        if not name or len(name.strip()) < 3:
            return ConnectorResult(error="Company name too short", source_name=self.name)

        cache_key = {"company": name.strip()}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            data = await fetch_json(
                f"{OC_API_BASE}/companies/search",
                params={"q": name, "jurisdiction_code": "us_ga", "per_page": "10"},
            )
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        companies = data.get("results", {}).get("companies", [])
        entities = []

        for item in companies[:10]:
            company = item.get("company", {})
            biz_id = str(uuid4())
            entities.append({
                "id": biz_id,
                "type": "BUSINESS",
                "name": company.get("name", ""),
                "legal_name": company.get("name", ""),
                "status": company.get("current_status", ""),
                "formation_date": company.get("incorporation_date", ""),
                "entity_type_business": company.get("company_type", ""),
                "jurisdiction": company.get("jurisdiction_code", ""),
                "opencorporates_url": company.get("opencorporates_url", ""),
                "registered_address": company.get("registered_address_in_full", ""),
            })

        result_data = {"entities": entities}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(
            entities=entities, raw_data=result_data,
            source_name=self.name, confidence=self.default_confidence,
        )

    async def _search_officers(self, entity: dict[str, Any]) -> ConnectorResult:
        name = entity.get("full_name") or f"{entity.get('first_name', '')} {entity.get('last_name', '')}"
        if not name or len(name.strip()) < 3:
            return ConnectorResult(error="Name too short", source_name=self.name)

        cache_key = {"officer": name.strip()}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            data = await fetch_json(
                f"{OC_API_BASE}/officers/search",
                params={"q": name, "jurisdiction_code": "us_ga", "per_page": "10"},
            )
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        officers = data.get("results", {}).get("officers", [])
        entities = []
        relationships = []

        for item in officers[:10]:
            officer = item.get("officer", {})
            company = officer.get("company", {})
            if not company:
                continue

            biz_id = str(uuid4())
            entities.append({
                "id": biz_id,
                "type": "BUSINESS",
                "name": company.get("name", ""),
                "jurisdiction": company.get("jurisdiction_code", ""),
                "opencorporates_url": company.get("opencorporates_url", ""),
            })

            if entity.get("id"):
                relationships.append({
                    "source_id": entity["id"], "target_id": biz_id,
                    "type": "OWNS_BUSINESS",
                    "properties": {
                        "sources": [self.name],
                        "role": officer.get("position", ""),
                    },
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
            await fetch_json(f"{OC_API_BASE}/companies/search", params={"q": "test", "per_page": "1"}, retries=1)
            return True
        except Exception:
            return False
