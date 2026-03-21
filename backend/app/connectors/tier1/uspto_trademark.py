"""USPTO Trademark — trademark and patent search.

API: https://developer.uspto.gov/ (free, API key recommended)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

USPTO_BASE = "https://developer.uspto.gov/ibd-api/v1/application/publications"


class USPTOTrademarkConnector(BaseConnector):
    name = "uspto_trademark"
    description = "USPTO — trademarks and patents by owner"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.85
    supported_input_types = [EntityType.PERSON, EntityType.BUSINESS]
    supported_output_types = [EntityType.BUSINESS]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        if entity.get("type") == "PERSON":
            search = entity.get("full_name") or entity.get("last_name", "")
        elif entity.get("type") == "BUSINESS":
            search = entity.get("name", "")
        else:
            return ConnectorResult(error="Requires PERSON or BUSINESS", source_name=self.name)

        if not search or len(search) < 3:
            return ConnectorResult(error="Search term too short", source_name=self.name)

        cache_key = {"query": search}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(entities=cached.get("entities", []),
                                   raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        try:
            data = await fetch_json(USPTO_BASE, params={
                "searchText": search, "start": "0", "rows": "10",
            })
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        results = data.get("response", {}).get("docs", data.get("results", []))
        if not isinstance(results, list):
            results = []

        entities = []
        for doc in results[:10]:
            ent_id = str(uuid4())
            entities.append({
                "id": ent_id, "type": "BUSINESS",
                "name": doc.get("inventionTitle", doc.get("applicantName", search)),
                "patent_number": doc.get("patentNumber", ""),
                "application_number": doc.get("applicationNumber", ""),
                "filing_date": doc.get("filingDate", ""),
                "applicant": doc.get("applicantName", ""),
                "entity_type_business": "IP Holder",
            })

        result_data = {"entities": entities}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, raw_data=result_data,
                               source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(USPTO_BASE, params={"searchText": "test", "rows": "1"}, retries=1)
            return True
        except Exception:
            return False
