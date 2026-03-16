"""FBI Crime Data API connector — crime statistics by county/state.

API: https://cde.ucr.cjis.gov/
Free, no auth required.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

FBI_API_BASE = "https://cde.ucr.cjis.gov/LATEST/webapp/api"

# Georgia state abbreviation and FIPS
GA_STATE_ABBR = "GA"

# Gwinnett County ORI (Originating Agency Identifier)
GWINNETT_ORIS = [
    "GA0670000",  # Gwinnett County Police
    "GA0670100",  # Lawrenceville PD
    "GA0670200",  # Duluth PD
    "GA0670600",  # Snellville PD
    "GA0670700",  # Suwanee PD
    "GA0670900",  # Norcross PD
]


class FBICrimeConnector(BaseConnector):
    name = "fbi_crime"
    description = "FBI Crime Data API — crime statistics by county"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.90
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.CRIME_RECORD]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        """Fetch crime statistics for the area around an address."""
        state = entity.get("state", "GA")
        county = entity.get("county", "")

        # Check cache
        cache_params = {"state": state, "county": county}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached,
                source_name=self.name,
                confidence=self.default_confidence,
            )

        # Try state-level crime estimates
        try:
            data = await fetch_json(
                f"{FBI_API_BASE}/api/estimates/states/{state}",
                params={"from": "2019", "to": "2023"},
            )
        except Exception as e:
            self.logger.error("FBI Crime API error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        if not data:
            return ConnectorResult(
                error="No crime data available",
                source_name=self.name,
            )

        # Parse crime data into entities
        entities = []
        relationships = []
        address_id = entity.get("id")

        # If we got results, create crime summary records
        results = data.get("results", data) if isinstance(data, dict) else data
        if isinstance(results, list):
            for record in results[-5:]:  # Last 5 years
                year = record.get("year", "")
                crime_id = str(uuid4())

                crime_entity = {
                    "id": crime_id,
                    "type": "CRIME_RECORD",
                    "incident_type": "annual_summary",
                    "jurisdiction": f"{state} - {county or 'Statewide'}",
                    "description": f"Crime summary for {year}",
                    "year": year,
                    "population": record.get("population"),
                    "violent_crime": record.get("violent_crime"),
                    "homicide": record.get("homicide"),
                    "rape": record.get("rape_revised") or record.get("rape_legacy"),
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
                        "properties": {
                            "sources": [self.name],
                            "distance_meters": 0,  # County-level, not specific
                        },
                    })

        result_data = {
            "entities": entities,
            "relationships": relationships,
            "raw": data if isinstance(data, dict) else {"results": data},
        }

        response = ConnectorResult(
            entities=entities,
            relationships=relationships,
            raw_data=result_data,
            source_name=self.name,
            confidence=self.default_confidence,
        )

        await set_cached(self.name, cache_params, result_data)
        return response

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(
                f"{FBI_API_BASE}/api/estimates/states/GA",
                params={"from": "2022", "to": "2022"},
                retries=1,
            )
            return True
        except Exception:
            return False
