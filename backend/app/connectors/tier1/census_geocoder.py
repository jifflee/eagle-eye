"""Census Geocoder connector — address to lat/long + census tract/block.

API: https://geocoding.geo.census.gov/geocoder/
Free, no auth, no rate limit documented.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

GEOCODER_BASE = "https://geocoding.geo.census.gov/geocoder"


class CensusGeocoderConnector(BaseConnector):
    name = "census_geocoder"
    description = "US Census Geocoder — address to coordinates + census tract"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=5.0, burst_size=10)
    default_confidence = 0.95
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.CENSUS_TRACT]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        """Geocode an address and return census tract info."""
        street = entity.get("street", "")
        city = entity.get("city", "")
        state = entity.get("state", "")
        zip_code = entity.get("zip", "")
        entity_id = entity.get("id", "unknown")

        if not street or not (city or zip_code):
            return ConnectorResult(error="Address requires street and city or zip")

        # Check cache — only cache raw API data, not entities/relationships
        cache_params = {"street": street, "city": city, "state": state, "zip": zip_code}
        cached = await get_cached(self.name, cache_params)

        if cached and "coordinates" in cached:
            # Rebuild entities/relationships from cached API data with current entity ID
            return self._build_result(entity_id, cached)

        # Geocode with geographies to get census tract
        params = {
            "street": street,
            "city": city,
            "state": state,
            "zip": zip_code,
            "benchmark": "Public_AR_Current",
            "vintage": "Current_Current",
            "format": "json",
        }

        try:
            data = await fetch_json(
                f"{GEOCODER_BASE}/geographies/address", params=params
            )
        except Exception as e:
            self.logger.error("Census Geocoder error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        result = data.get("result", {})
        matches = result.get("addressMatches", [])

        if not matches:
            return ConnectorResult(
                error="No address match found",
                raw_data=data,
                source_name=self.name,
            )

        match = matches[0]
        coordinates = match.get("coordinates", {})
        geographies = match.get("geographies", {})
        tracts = geographies.get("Census Tracts", [])
        tract_info = tracts[0] if tracts else {}

        # Cache only the raw API response data (no entity IDs)
        cache_data = {
            "coordinates": coordinates,
            "matched_address": match.get("matchedAddress", ""),
            "tract_info": tract_info,
        }
        await set_cached(self.name, cache_params, cache_data)

        return self._build_result(entity_id, cache_data)

    def _build_result(self, entity_id: str, data: dict) -> ConnectorResult:
        """Build ConnectorResult from raw geocoding data + current entity ID."""
        coordinates = data.get("coordinates", {})
        tract_info = data.get("tract_info", {})

        address_updates = {
            "latitude": coordinates.get("y"),
            "longitude": coordinates.get("x"),
            "matched_address": data.get("matched_address", ""),
        }

        entities = []
        relationships = []

        if tract_info:
            tract_id = str(uuid4())
            entities.append({
                "id": tract_id,
                "type": "CENSUS_TRACT",
                "tract_number": tract_info.get("TRACT", ""),
                "block_number": tract_info.get("BLOCK", ""),
                "county": tract_info.get("COUNTY", ""),
                "state": tract_info.get("STATE", ""),
                "geoid": tract_info.get("GEOID", ""),
            })

            relationships.append({
                "source_id": entity_id,
                "target_id": tract_id,
                "type": "IN_CENSUS_TRACT",
                "properties": {"sources": [self.name]},
            })

        return ConnectorResult(
            entities=entities,
            relationships=relationships,
            raw_data={
                "coordinates": coordinates,
                "matched_address": data.get("matched_address"),
                "tract_info": tract_info,
                "address_updates": address_updates,
                "entities": entities,
                "relationships": relationships,
            },
            source_name=self.name,
            confidence=self.default_confidence,
        )

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(
                f"{GEOCODER_BASE}/benchmarks",
                params={"format": "json"},
                retries=1,
            )
            return True
        except Exception:
            return False
