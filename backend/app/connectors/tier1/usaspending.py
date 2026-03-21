"""USASpending connector — federal contracts and grants.

API: https://api.usaspending.gov/ (free, no auth)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

USA_BASE = "https://api.usaspending.gov/api/v2"


class USASpendingConnector(BaseConnector):
    name = "usaspending"
    description = "USASpending — federal contracts and grants"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.85
    supported_input_types = [EntityType.BUSINESS, EntityType.PERSON]
    supported_output_types = [EntityType.BUSINESS]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        search_term = ""
        if entity.get("type") == "BUSINESS":
            search_term = entity.get("name", "")
        elif entity.get("type") == "PERSON":
            search_term = entity.get("full_name") or entity.get("last_name", "")

        if not search_term or len(search_term) < 3:
            return ConnectorResult(error="Search term too short", source_name=self.name)

        cache_key = {"query": search_term}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(entities=cached.get("entities", []), relationships=cached.get("relationships", []),
                                   raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        try:
            data = await fetch_json(f"{USA_BASE}/search/spending_by_award/", method="POST", json_body={
                "filters": {"recipient_search_text": [search_term], "time_period": [{"start_date": "2020-01-01", "end_date": "2026-12-31"}]},
                "fields": ["Award ID", "Recipient Name", "Award Amount", "Awarding Agency", "Award Type", "Start Date"],
                "limit": 10, "page": 1, "sort": "Award Amount", "order": "desc",
            })
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        results = data.get("results", [])
        entities = []
        relationships = []

        for r in results[:10]:
            biz_id = str(uuid4())
            entities.append({
                "id": biz_id, "type": "BUSINESS",
                "name": r.get("Recipient Name", ""),
                "award_id": r.get("Award ID", ""),
                "award_amount": r.get("Award Amount"),
                "awarding_agency": r.get("Awarding Agency", ""),
                "award_type": r.get("Award Type", ""),
                "start_date": r.get("Start Date", ""),
                "federal_contractor": True,
            })

            if entity.get("id"):
                relationships.append({
                    "source_id": entity["id"], "target_id": biz_id,
                    "type": "AFFILIATED_WITH", "properties": {"sources": [self.name], "relationship_subtype": "federal_award"},
                })

        result_data = {"entities": entities, "relationships": relationships}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, relationships=relationships,
                               raw_data=result_data, source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(f"{USA_BASE}/references/agency/", retries=1)
            return True
        except Exception:
            return False
