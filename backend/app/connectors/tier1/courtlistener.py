"""CourtListener connector — federal/state court records.

API: https://www.courtlistener.com/help/api/rest/ (free, non-profit)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

CL_BASE = "https://www.courtlistener.com/api/rest/v4"


class CourtListenerConnector(BaseConnector):
    name = "courtlistener"
    description = "CourtListener — federal/state court records"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.85
    supported_input_types = [EntityType.PERSON, EntityType.BUSINESS]
    supported_output_types = [EntityType.CASE]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        entity_type = entity.get("type", "")
        if entity_type == "PERSON":
            search_term = entity.get("full_name") or f"{entity.get('first_name', '')} {entity.get('last_name', '')}"
        elif entity_type == "BUSINESS":
            search_term = entity.get("name", "")
        else:
            return ConnectorResult(error="Unsupported entity type", source_name=self.name)

        if not search_term or len(search_term.strip()) < 3:
            return ConnectorResult(error="Search term too short", source_name=self.name)

        cache_params = {"query": search_term.strip()}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            data = await fetch_json(
                f"{CL_BASE}/search/",
                params={"q": search_term, "type": "r", "order_by": "score desc"},
            )
        except Exception as e:
            self.logger.error("CourtListener error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        results = data.get("results", [])
        entities = []
        relationships = []

        for result in results[:10]:
            case_id = str(uuid4())
            case_name = result.get("caseName", result.get("case_name", ""))
            docket_number = result.get("docketNumber", result.get("docket_number", ""))

            entities.append({
                "id": case_id,
                "type": "CASE",
                "case_number": docket_number,
                "case_name": case_name,
                "court_name": result.get("court", ""),
                "court_type": "federal",
                "filing_date": result.get("dateFiled", result.get("date_filed")),
                "status": result.get("status", ""),
                "docket_url": f"https://www.courtlistener.com{result.get('absolute_url', '')}",
            })

            if entity.get("id"):
                relationships.append({
                    "source_id": entity["id"], "target_id": case_id,
                    "type": "NAMED_IN_CASE",
                    "properties": {"sources": [self.name], "party_type": "unknown"},
                })

        result_data = {"entities": entities, "relationships": relationships}
        await set_cached(self.name, cache_params, result_data)
        return ConnectorResult(
            entities=entities, relationships=relationships,
            raw_data=result_data, source_name=self.name, confidence=self.default_confidence,
        )

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(f"{CL_BASE}/search/", params={"q": "test", "type": "r"}, retries=1)
            return True
        except Exception:
            return False
