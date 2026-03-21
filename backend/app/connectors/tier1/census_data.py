"""Census Data API connector — demographics by census tract.

API: https://api.census.gov/data/
Free, key recommended but not required for low volume.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

CENSUS_API_BASE = "https://api.census.gov/data"

# ACS 5-Year Estimate variables
ACS_VARIABLES = {
    "B01003_001E": "population",
    "B19013_001E": "median_income",
    "B25001_001E": "housing_units",
    "B25003_002E": "owner_occupied",
    "B17001_002E": "poverty_count",
    "B23025_005E": "unemployed",
    "B23025_002E": "labor_force",
    "B01002_001E": "median_age",
}


class CensusDataConnector(BaseConnector):
    name = "census_data"
    description = "Census Data API — demographics by tract"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.95
    supported_input_types = [EntityType.CENSUS_TRACT, EntityType.ADDRESS]
    supported_output_types = [EntityType.CENSUS_TRACT]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        """Fetch demographics for a census tract."""
        # Get tract identifiers — check both FIPS-specific and general field names
        state_fips = entity.get("state_fips") or entity.get("state", "")
        county_fips = entity.get("county_fips") or entity.get("county", "")
        tract_number = entity.get("tract_number", "")

        if not (state_fips and county_fips and tract_number):
            return ConnectorResult(
                error="Requires state FIPS, county FIPS, and tract number",
                source_name=self.name,
            )

        # Check cache
        cache_params = {
            "state": state_fips,
            "county": county_fips,
            "tract": tract_number,
        }
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                raw_data=cached,
                source_name=self.name,
                confidence=self.default_confidence,
            )

        # Query ACS 5-Year estimates
        variables = ",".join(ACS_VARIABLES.keys())
        params = {
            "get": f"NAME,{variables}",
            "for": f"tract:{tract_number}",
            "in": f"state:{state_fips} county:{county_fips}",
        }

        try:
            data = await fetch_json(f"{CENSUS_API_BASE}/2022/acs/acs5", params=params)
        except Exception as e:
            self.logger.error("Census Data API error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        if not data or len(data) < 2:
            return ConnectorResult(
                error="No census data found for tract",
                raw_data={"response": data},
                source_name=self.name,
            )

        # Parse response — first row is headers, second is data
        headers = data[0]
        values = data[1]
        raw = dict(zip(headers, values))

        # Build demographics
        demographics = {}
        for var_code, field_name in ACS_VARIABLES.items():
            val = raw.get(var_code)
            if val and val not in ("-666666666", None):
                try:
                    demographics[field_name] = float(val)
                except (ValueError, TypeError):
                    demographics[field_name] = None

        # Calculate derived metrics
        population = demographics.get("population", 0)
        housing_units = demographics.get("housing_units", 0)
        owner_occupied = demographics.get("owner_occupied", 0)
        poverty_count = demographics.get("poverty_count", 0)
        unemployed = demographics.get("unemployed", 0)
        labor_force = demographics.get("labor_force", 0)

        if housing_units and housing_units > 0:
            demographics["owner_occupied_pct"] = round(
                (owner_occupied / housing_units) * 100, 1
            )
        if population and population > 0:
            demographics["poverty_rate"] = round(
                (poverty_count / population) * 100, 1
            )
        if labor_force and labor_force > 0:
            demographics["unemployment_rate"] = round(
                (unemployed / labor_force) * 100, 1
            )

        # Build census tract entity update
        tract_entity = {
            "id": entity.get("id", str(uuid4())),
            "type": "CENSUS_TRACT",
            "tract_number": tract_number,
            "county": county_fips,
            "state": state_fips,
            "name": raw.get("NAME", ""),
            **demographics,
        }

        result_data = {
            "entities": [tract_entity],
            "demographics": demographics,
            "raw": raw,
        }

        response = ConnectorResult(
            entities=[tract_entity],
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
                f"{CENSUS_API_BASE}/2022/acs/acs5",
                params={"get": "NAME", "for": "state:13"},
                retries=1,
            )
            return True
        except Exception:
            return False
