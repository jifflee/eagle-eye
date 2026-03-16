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

        if not street or not (city or zip_code):
            return ConnectorResult(error="Address requires street and city or zip")

        # Check cache
        cache_params = {"street": street, "city": city, "state": state, "zip": zip_code}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached,
                source_name=self.name,
                confidence=self.default_confidence,
            )

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

        # Extract census tract info
        tracts = geographies.get("Census Tracts", [])
        tract_info = tracts[0] if tracts else {}

        # Update the address entity with coordinates
        address_updates = {
            "latitude": coordinates.get("y"),
            "longitude": coordinates.get("x"),
            "matched_address": match.get("matchedAddress", ""),
        }

        entities = []
        relationships = []

        # Create census tract entity if we have tract data
        if tract_info:
            tract_id = str(uuid4())
            tract_entity = {
                "id": tract_id,
                "type": "CENSUS_TRACT",
                "tract_number": tract_info.get("TRACT", ""),
                "block_number": tract_info.get("BLOCK", ""),
                "county": tract_info.get("COUNTY", ""),
                "state": tract_info.get("STATE", ""),
                "geoid": tract_info.get("GEOID", ""),
            }
            entities.append(tract_entity)

            # Relationship: ADDRESS -> IN_CENSUS_TRACT -> CENSUS_TRACT
            relationships.append({
                "source_id": entity.get("id"),
                "target_id": tract_id,
                "type": "IN_CENSUS_TRACT",
                "properties": {"sources": [self.name]},
            })

        response = ConnectorResult(
            entities=entities,
            relationships=relationships,
            raw_data={
                "coordinates": coordinates,
                "matched_address": match.get("matchedAddress"),
                "tract_info": tract_info,
                "address_updates": address_updates,
                "entities": entities,
                "relationships": relationships,
            },
            source_name=self.name,
            confidence=self.default_confidence,
        )

        # Cache the result
        await set_cached(self.name, cache_params, response.raw_data or {})

        return response

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        """Enrich is the same as discover for geocoding."""
        return await self.discover(entity)

    async def validate(self) -> bool:
        """Check if the Census Geocoder API is reachable."""
        try:
            await fetch_json(
                f"{GEOCODER_BASE}/benchmarks",
                params={"format": "json"},
                retries=1,
            )
            return True
        except Exception:
            return False
