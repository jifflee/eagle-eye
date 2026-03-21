"""GPO GovInfo — federal publications, court opinions, congressional records.

API: https://api.govinfo.gov/ (free, data.gov key or DEMO_KEY)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

GOVINFO_BASE = "https://api.govinfo.gov"
API_KEY = "DEMO_KEY"


class GovInfoConnector(BaseConnector):
    name = "govinfo"
    description = "GovInfo — federal publications and court opinions"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=1.0, burst_size=3)
    default_confidence = 0.80
    supported_input_types = [EntityType.PERSON, EntityType.BUSINESS]
    supported_output_types = [EntityType.CASE]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        name = ""
        if entity.get("type") == "PERSON":
            name = entity.get("full_name") or f"{entity.get('first_name', '')} {entity.get('last_name', '')}"
        elif entity.get("type") == "BUSINESS":
            name = entity.get("name", "")

        if not name or len(name.strip()) < 3:
            return ConnectorResult(error="Name required", source_name=self.name)

        cache_key = {"query": name.strip()}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(entities=cached.get("entities", []), relationships=cached.get("relationships", []),
                                   raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        try:
            data = await fetch_json(f"{GOVINFO_BASE}/search", params={
                "query": name, "pageSize": "10", "offsetMark": "*",
                "collection": "USCOURTS", "api_key": API_KEY,
            })
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        results = data.get("results", [])
        entities = []
        relationships = []

        for r in results[:10]:
            case_id = str(uuid4())
            entities.append({
                "id": case_id, "type": "CASE",
                "case_number": r.get("packageId", ""),
                "case_name": r.get("title", ""),
                "court_name": r.get("courtName", r.get("publisher", "")),
                "court_type": "federal",
                "filing_date": r.get("dateIssued", ""),
                "docket_url": r.get("packageLink", ""),
            })
            if entity.get("id"):
                relationships.append({
                    "source_id": entity["id"], "target_id": case_id,
                    "type": "NAMED_IN_CASE", "properties": {"sources": [self.name]},
                })

        result_data = {"entities": entities, "relationships": relationships}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, relationships=relationships,
                               raw_data=result_data, source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(f"{GOVINFO_BASE}/collections", params={"api_key": API_KEY}, retries=1)
            return True
        except Exception:
            return False
