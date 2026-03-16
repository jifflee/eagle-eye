"""OpenFEMA connector — disaster declarations and flood data.

API: https://www.fema.gov/about/openfema/api (free, no auth)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

FEMA_BASE = "https://www.fema.gov/api/open/v2"


class OpenFEMAConnector(BaseConnector):
    name = "openfema"
    description = "OpenFEMA — disaster declarations and flood data"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=5.0, burst_size=10)
    default_confidence = 0.90
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = []  # Enriches ADDRESS, doesn't create new types

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        state = entity.get("state", "")
        county = entity.get("county", "")
        zip_code = entity.get("zip", "")

        if not state:
            return ConnectorResult(error="State required", source_name=self.name)

        cache_params = {"state": state, "county": county}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        # Get disaster declarations for the state/county
        filter_str = f"state eq '{state}'"
        if county:
            filter_str += f" and designatedArea eq '{county} (County)'"

        try:
            data = await fetch_json(
                f"{FEMA_BASE}/DisasterDeclarationsSummaries",
                params={
                    "$filter": filter_str,
                    "$orderby": "declarationDate desc",
                    "$top": "20",
                    "$select": "disasterNumber,declarationDate,declarationTitle,incidentType,designatedArea,state",
                },
            )
        except Exception as e:
            self.logger.error("OpenFEMA error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        declarations = data.get("DisasterDeclarationsSummaries", [])
        result_data = {
            "disaster_count": len(declarations),
            "recent_disasters": [
                {
                    "number": d.get("disasterNumber"),
                    "date": d.get("declarationDate"),
                    "title": d.get("declarationTitle"),
                    "type": d.get("incidentType"),
                    "area": d.get("designatedArea"),
                }
                for d in declarations[:10]
            ],
            "address_updates": {
                "disaster_count": len(declarations),
                "most_recent_disaster": declarations[0].get("declarationTitle") if declarations else None,
            },
        }

        await set_cached(self.name, cache_params, result_data)
        return ConnectorResult(raw_data=result_data, source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(f"{FEMA_BASE}/DisasterDeclarationsSummaries", params={"$top": "1"}, retries=1)
            return True
        except Exception:
            return False
