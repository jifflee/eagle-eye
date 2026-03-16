"""Gwinnett Courts connector — county case search.

Source: https://www.gwinnettcourts.com/casesearch/ (web scraping)
"""

from __future__ import annotations

import re
from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_text

COURTS_SEARCH = "https://www.gwinnettcourts.com/casesearch/"


class GwinnettCourtsConnector(BaseConnector):
    name = "gwinnett_courts"
    description = "Gwinnett Courts — county case search"
    tier = 2
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=1.0, burst_size=2)
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
            return ConnectorResult(error="Requires PERSON or BUSINESS entity", source_name=self.name)

        if not search_term or len(search_term.strip()) < 3:
            return ConnectorResult(error="Search term too short", source_name=self.name)

        cache_key = {"query": search_term.strip()}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            html = await fetch_text(COURTS_SEARCH, params={"name": search_term})
        except Exception as e:
            self.logger.error("Gwinnett Courts error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        entities = []
        relationships = []

        # Extract case numbers and types from search results
        case_pattern = re.findall(
            r'(\d{2,4}-\w{2}-\d{4,8})\s*</?\w+[^>]*>\s*(?:<[^>]+>)*\s*(\w+)',
            html,
        )

        for case_number, case_type_raw in case_pattern[:15]:
            case_id = str(uuid4())
            case_type = "civil" if "CV" in case_number.upper() else "criminal" if "CR" in case_number.upper() else "traffic" if "TR" in case_number.upper() else "other"

            entities.append({
                "id": case_id,
                "type": "CASE",
                "case_number": case_number,
                "court_name": "Gwinnett County Court",
                "court_type": "county",
                "case_type": case_type,
                "status": "unknown",
            })

            if entity.get("id"):
                relationships.append({
                    "source_id": entity["id"], "target_id": case_id,
                    "type": "NAMED_IN_CASE",
                    "properties": {"sources": [self.name], "party_type": "unknown"},
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
            await fetch_text(COURTS_SEARCH, retries=1)
            return True
        except Exception:
            return False
