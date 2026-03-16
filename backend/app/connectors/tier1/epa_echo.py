"""EPA ECHO connector — environmental facilities, violations, enforcement.

API: https://echo.epa.gov/tools/web-services (free, no auth)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

ECHO_BASE = "https://echodata.epa.gov/echo"


class EPAEchoConnector(BaseConnector):
    name = "epa_echo"
    description = "EPA ECHO — environmental facilities and violations"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.90
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.ENVIRONMENTAL_FACILITY]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        lat = entity.get("latitude")
        lon = entity.get("longitude")
        zip_code = entity.get("zip", "")

        if not ((lat and lon) or zip_code):
            return ConnectorResult(error="Requires coordinates or zip", source_name=self.name)

        cache_params = {"lat": lat, "lon": lon, "zip": zip_code}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        params: dict[str, Any] = {"output": "JSON", "p_radius": "3"}
        if lat and lon:
            params["p_lat"] = str(lat)
            params["p_long"] = str(lon)
        else:
            params["p_zip"] = zip_code

        try:
            data = await fetch_json(f"{ECHO_BASE}/echo_rest_services.get_facilities", params=params)
        except Exception as e:
            self.logger.error("EPA ECHO error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        facilities_raw = data.get("Results", {}).get("Facilities", [])
        entities = []
        relationships = []
        address_id = entity.get("id")

        for fac in facilities_raw[:20]:
            fac_id = str(uuid4())
            entities.append({
                "id": fac_id,
                "type": "ENVIRONMENTAL_FACILITY",
                "facility_name": fac.get("FacName", ""),
                "facility_type": fac.get("FacSICCodes", ""),
                "agency": "EPA",
                "compliance_status": fac.get("CurrSvFlag", "Unknown"),
                "violations_count": int(fac.get("CurrVioFlag", "0") == "Y"),
                "address": fac.get("FacStreet", ""),
                "city": fac.get("FacCity", ""),
                "state": fac.get("FacState", ""),
                "registry_id": fac.get("RegistryID", ""),
            })
            if address_id:
                relationships.append({
                    "source_id": address_id, "target_id": fac_id,
                    "type": "HAS_ENV_FACILITY",
                    "properties": {"sources": [self.name], "distance_meters": None},
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
            await fetch_json(
                f"{ECHO_BASE}/echo_rest_services.get_facilities",
                params={"output": "JSON", "p_zip": "30043", "p_radius": "1"},
                retries=1,
            )
            return True
        except Exception:
            return False
