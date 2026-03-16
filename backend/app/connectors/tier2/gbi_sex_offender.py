"""GBI Sex Offender Registry connector.

Source: https://state.sor.gbi.ga.gov/sort_public/ (web scraping)
"""

from __future__ import annotations

import re
from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_text

GBI_SOR_SEARCH = "https://state.sor.gbi.ga.gov/sort_public/results"


class GBISexOffenderConnector(BaseConnector):
    name = "gbi_sex_offender"
    description = "GBI Sex Offender Registry"
    tier = 2
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=1.0, burst_size=2)
    default_confidence = 0.90
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.PERSON, EntityType.CRIME_RECORD]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        zip_code = entity.get("zip", "")
        if not zip_code:
            return ConnectorResult(error="ZIP code required", source_name=self.name)

        cache_key = {"zip": zip_code}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            html = await fetch_text(
                GBI_SOR_SEARCH,
                params={"zip": zip_code, "radius": "1"},
            )
        except Exception as e:
            self.logger.error("GBI SOR error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        entities = []
        relationships = []
        address_id = entity.get("id")

        # Extract offender names and addresses from results
        name_matches = re.findall(r'offender[^"]*"[^>]*>\s*([^<]+)', html, re.IGNORECASE)
        address_matches = re.findall(r'(\d+\s+[A-Z][^<,]+,\s*[A-Z]{2}\s+\d{5})', html)

        for i, name in enumerate(name_matches[:10]):
            name = name.strip()
            if not name or len(name) < 3:
                continue

            person_id = str(uuid4())
            crime_id = str(uuid4())
            name_parts = name.split()

            entities.append({
                "id": person_id,
                "type": "PERSON",
                "full_name": name,
                "first_name": name_parts[0] if name_parts else "",
                "last_name": name_parts[-1] if len(name_parts) > 1 else "",
                "sex_offender_registry": True,
            })

            entities.append({
                "id": crime_id,
                "type": "CRIME_RECORD",
                "incident_type": "sex_offense",
                "jurisdiction": "Georgia",
                "description": "Registered sex offender",
            })

            relationships.append({
                "source_id": person_id, "target_id": crime_id,
                "type": "NAMED_IN_CASE",
                "properties": {"sources": [self.name], "party_type": "offender"},
            })

            if address_id:
                relationships.append({
                    "source_id": address_id, "target_id": crime_id,
                    "type": "HAS_CRIME_NEAR",
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
            await fetch_text(GBI_SOR_SEARCH, params={"zip": "30043"}, retries=1)
            return True
        except Exception:
            return False
