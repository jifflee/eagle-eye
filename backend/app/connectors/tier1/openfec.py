"""OpenFEC connector — federal campaign contributions.

API: https://api.open.fec.gov/ (free, requires data.gov API key)
Finds who at an address donates to political campaigns + their employer.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.config import settings
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

FEC_BASE = "https://api.open.fec.gov/v1"
# Use DEMO_KEY if no key configured — 1000 requests/hour
API_KEY = settings.census_api_key or "DEMO_KEY"


class OpenFECConnector(BaseConnector):
    name = "openfec"
    description = "OpenFEC — campaign contributions by name/zip"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.85
    supported_input_types = [EntityType.PERSON, EntityType.ADDRESS]
    supported_output_types = [EntityType.PERSON]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        entity_type = entity.get("type", "")

        if entity_type == "PERSON":
            name = entity.get("full_name") or f"{entity.get('first_name', '')} {entity.get('last_name', '')}"
            params = {"contributor_name": name, "api_key": API_KEY, "per_page": "10", "sort": "-contribution_receipt_date"}
        elif entity_type == "ADDRESS":
            zip_code = entity.get("zip", "")
            if not zip_code:
                return ConnectorResult(error="ZIP required for address search", source_name=self.name)
            params = {"contributor_zip": zip_code, "api_key": API_KEY, "per_page": "20", "sort": "-contribution_receipt_date"}
        else:
            return ConnectorResult(error="Requires PERSON or ADDRESS", source_name=self.name)

        cache_key = {k: v for k, v in params.items() if k != "api_key"}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(entities=cached.get("entities", []), relationships=cached.get("relationships", []),
                                   raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        try:
            data = await fetch_json(f"{FEC_BASE}/schedules/schedule_a/", params=params)
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        results = data.get("results", [])
        entities = []
        relationships = []
        seen_names: set[str] = set()

        for r in results[:15]:
            name = r.get("contributor_name", "")
            if not name or name in seen_names:
                continue
            seen_names.add(name)

            person_id = str(uuid4())
            parts = name.split(", ")
            last = parts[0] if parts else name
            first = parts[1] if len(parts) > 1 else ""

            entities.append({
                "id": person_id, "type": "PERSON",
                "full_name": f"{first} {last}".strip(), "first_name": first, "last_name": last,
                "employer": r.get("contributor_employer", ""),
                "occupation": r.get("contributor_occupation", ""),
                "city": r.get("contributor_city", ""),
                "state": r.get("contributor_state", ""),
                "zip": r.get("contributor_zip", ""),
                "contribution_amount": r.get("contribution_receipt_amount"),
                "contribution_date": r.get("contribution_receipt_date"),
                "committee": r.get("committee", {}).get("name", ""),
            })

            if entity.get("id") and entity_type == "ADDRESS":
                relationships.append({
                    "source_id": person_id, "target_id": entity["id"],
                    "type": "LIVES_AT", "properties": {"sources": [self.name], "verified": False},
                })

        result_data = {"entities": entities, "relationships": relationships}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, relationships=relationships,
                               raw_data=result_data, source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(f"{FEC_BASE}/candidates/", params={"api_key": API_KEY, "per_page": "1"}, retries=1)
            return True
        except Exception:
            return False
