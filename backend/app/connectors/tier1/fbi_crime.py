"""FBI Crime Data Explorer connector — crime statistics by state/county.

API: https://cde.ucr.cjis.gov/LATEST/webapp/#/pages/explorer/crime/crime-trend
Free, no auth required. Uses the public Crime Data Explorer API.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

# Crime Data Explorer public API
CDE_API_BASE = "https://cde.ucr.cjis.gov/LATEST/webapp/api"

# State FIPS codes
STATE_FIPS = {"GA": "13", "AL": "01", "FL": "12", "SC": "45", "TN": "47", "NC": "37"}

# Gwinnett County FIPS within Georgia
GWINNETT_COUNTY_FIPS = "135"


class FBICrimeConnector(BaseConnector):
    name = "fbi_crime"
    description = "FBI Crime Data Explorer — crime statistics by state/county"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.90
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.CRIME_RECORD]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        """Fetch crime statistics for the area around an address."""
        state = entity.get("state", "GA").upper()
        state_fips = STATE_FIPS.get(state, "13")

        cache_params = {"state": state, "state_fips": state_fips}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        # Try the Crime Data Explorer estimates endpoint
        try:
            data = await fetch_json(
                f"{CDE_API_BASE}/estimates/states/{state_fips}",
                retries=2,
            )
        except Exception:
            # Fallback: try the national estimates endpoint
            try:
                data = await fetch_json(
                    f"{CDE_API_BASE}/estimates/national",
                    retries=1,
                )
            except Exception as e:
                self.logger.warning("FBI CDE API unavailable: %s", e)
                return ConnectorResult(error=str(e), source_name=self.name)

        if not data:
            return ConnectorResult(error="No crime data available", source_name=self.name)

        entities = []
        relationships = []
        address_id = entity.get("id")

        # Parse response — CDE returns various formats
        results = data if isinstance(data, list) else data.get("results", data.get("data", []))
        if isinstance(results, dict):
            results = [results]

        if isinstance(results, list):
            for record in results[-5:]:
                year = record.get("year", record.get("data_year", ""))
                crime_id = str(uuid4())

                crime_entity = {
                    "id": crime_id,
                    "type": "CRIME_RECORD",
                    "incident_type": "annual_summary",
                    "jurisdiction": f"{state} Statewide",
                    "description": f"Crime summary for {year}",
                    "year": year,
                    "population": record.get("population"),
                    "violent_crime": record.get("violent_crime"),
                    "homicide": record.get("homicide"),
                    "rape": record.get("rape_revised") or record.get("rape_legacy") or record.get("rape"),
                    "robbery": record.get("robbery"),
                    "aggravated_assault": record.get("aggravated_assault"),
                    "property_crime": record.get("property_crime"),
                    "burglary": record.get("burglary"),
                    "larceny": record.get("larceny"),
                    "motor_vehicle_theft": record.get("motor_vehicle_theft"),
                    "arson": record.get("arson"),
                }
                entities.append(crime_entity)

                if address_id:
                    relationships.append({
                        "source_id": address_id,
                        "target_id": crime_id,
                        "type": "HAS_CRIME_NEAR",
                        "properties": {"sources": [self.name]},
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
            await fetch_json(f"{CDE_API_BASE}/estimates/national", retries=1)
            return True
        except Exception:
            return False
