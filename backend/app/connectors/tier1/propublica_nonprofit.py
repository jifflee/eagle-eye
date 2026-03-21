"""ProPublica Nonprofit Explorer — IRS 990 data.

API: https://projects.propublica.org/nonprofits/api/ (free, no auth)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

PP_BASE = "https://projects.propublica.org/nonprofits/api/v2"


class ProPublicaNonprofitConnector(BaseConnector):
    name = "propublica_nonprofit"
    description = "ProPublica — nonprofit orgs, officers, revenue"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.80
    supported_input_types = [EntityType.PERSON, EntityType.ADDRESS, EntityType.BUSINESS]
    supported_output_types = [EntityType.BUSINESS, EntityType.PERSON]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        entity_type = entity.get("type", "")
        if entity_type == "ADDRESS":
            search = entity.get("city", "") + " " + entity.get("state", "")
            state = entity.get("state", "")
        elif entity_type == "PERSON":
            search = entity.get("full_name") or entity.get("last_name", "")
            state = ""
        elif entity_type == "BUSINESS":
            search = entity.get("name", "")
            state = ""
        else:
            return ConnectorResult(error="Unsupported entity type", source_name=self.name)

        if not search or len(search.strip()) < 3:
            return ConnectorResult(error="Search term too short", source_name=self.name)

        cache_key = {"query": search.strip(), "state": state}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(entities=cached.get("entities", []), relationships=cached.get("relationships", []),
                                   raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        params = {"q": search.strip()}
        if state:
            params["state[id]"] = state

        try:
            data = await fetch_json(f"{PP_BASE}/search.json", params=params)
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        orgs = data.get("organizations", [])
        entities = []
        relationships = []

        for org in orgs[:10]:
            biz_id = str(uuid4())
            entities.append({
                "id": biz_id, "type": "BUSINESS",
                "name": org.get("name", ""),
                "ein": org.get("ein"),
                "city": org.get("city", ""),
                "state": org.get("state", ""),
                "ntee_code": org.get("ntee_code", ""),
                "revenue": org.get("income_amount"),
                "assets": org.get("asset_amount"),
                "entity_type_business": "Nonprofit",
                "nonprofit": True,
            })

            if entity.get("id"):
                rel_type = "LOCATED_AT" if entity_type == "ADDRESS" else "AFFILIATED_WITH"
                relationships.append({
                    "source_id": biz_id, "target_id": entity["id"],
                    "type": rel_type, "properties": {"sources": [self.name]},
                })

        result_data = {"entities": entities, "relationships": relationships}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, relationships=relationships,
                               raw_data=result_data, source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(f"{PP_BASE}/search.json", params={"q": "test"}, retries=1)
            return True
        except Exception:
            return False
