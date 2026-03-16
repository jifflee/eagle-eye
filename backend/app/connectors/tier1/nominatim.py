"""OSM Nominatim connector — backup geocoder.

API: https://nominatim.openstreetmap.org/ (free, 1 req/sec strict)
"""

from __future__ import annotations

from typing import Any

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

NOMINATIM_BASE = "https://nominatim.openstreetmap.org"


class NominatimConnector(BaseConnector):
    name = "nominatim"
    description = "OSM Nominatim — backup geocoder"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=1.0, burst_size=1)  # Strict 1 req/sec
    default_confidence = 0.80
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = []

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        street = entity.get("street", "")
        city = entity.get("city", "")
        state = entity.get("state", "")
        zip_code = entity.get("zip", "")

        query = f"{street}, {city}, {state} {zip_code}".strip(", ")
        if not query:
            return ConnectorResult(error="Address required", source_name=self.name)

        cache_params = {"q": query}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        try:
            data = await fetch_json(
                f"{NOMINATIM_BASE}/search",
                params={"q": query, "format": "json", "addressdetails": "1", "limit": "1", "countrycodes": "us"},
            )
        except Exception as e:
            self.logger.error("Nominatim error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        if not data:
            return ConnectorResult(error="No geocoding result", source_name=self.name)

        result = data[0]
        result_data = {
            "latitude": float(result.get("lat", 0)),
            "longitude": float(result.get("lon", 0)),
            "display_name": result.get("display_name", ""),
            "address_components": result.get("address", {}),
            "osm_type": result.get("osm_type"),
            "osm_id": result.get("osm_id"),
            "address_updates": {
                "latitude": float(result.get("lat", 0)),
                "longitude": float(result.get("lon", 0)),
            },
        }

        await set_cached(self.name, cache_params, result_data)
        return ConnectorResult(raw_data=result_data, source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(
                f"{NOMINATIM_BASE}/search",
                params={"q": "Atlanta, GA", "format": "json", "limit": "1"},
                retries=1,
            )
            return True
        except Exception:
            return False
