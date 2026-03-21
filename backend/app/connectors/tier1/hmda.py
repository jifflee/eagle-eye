"""HMDA connector — mortgage lending data by census tract.

API: https://ffiec.cfpb.gov/v2/data-browser-api/
Free, no auth. Queries by state FIPS + county FIPS + tract from geocoder.
Returns loan origination/denial counts, total amounts, breakdowns by loan type.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

HMDA_BASE = "https://ffiec.cfpb.gov/v2/data-browser-api/view/aggregations"

# action_taken codes: 1=originated, 3=denied, 6=purchased
ACTION_LABELS = {"1": "originated", "3": "denied", "6": "purchased"}

# loan_type codes: 1=conventional, 2=FHA, 3=VA, 4=USDA
LOAN_TYPE_LABELS = {"1": "conventional", "2": "FHA", "3": "VA", "4": "USDA"}


class HMDAConnector(BaseConnector):
    name = "hmda"
    description = "HMDA — mortgage lending data by census tract"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.95
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.FINANCIAL_RECORD]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        """Fetch mortgage lending summary for the census tract of an address."""
        state_fips = entity.get("state_fips", "")
        county_fips = entity.get("county_fips", "")
        tract = entity.get("geoid", "")  # Full tract GEOID from geocoder

        if not state_fips or not county_fips:
            return ConnectorResult(error="Requires state_fips and county_fips from geocoder", source_name=self.name)

        county_code = f"{state_fips}{county_fips}"

        cache_key = {"county": county_code, "tract": tract}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        entities = []
        relationships = []
        address_id = entity.get("id")

        # Query 1: Originations vs denials for the county (or tract if available)
        params: dict[str, str] = {
            "states": state_fips.lstrip("0") if len(state_fips) == 2 else state_fips,
            "counties": county_code,
            "years": "2022",
            "actions_taken": "1,3",
        }
        if tract:
            params["tracts"] = tract

        try:
            action_data = await fetch_json(HMDA_BASE, params=params)
        except Exception as e:
            return ConnectorResult(error=f"HMDA API error: {e}", source_name=self.name)

        aggregations = action_data.get("aggregations", [])
        originated = next((a for a in aggregations if a.get("actions_taken") == "1"), {})
        denied = next((a for a in aggregations if a.get("actions_taken") == "3"), {})

        record_id = str(uuid4())
        scope = f"tract {tract}" if tract else f"county {county_code}"

        mortgage_entity = {
            "id": record_id,
            "type": "FINANCIAL_RECORD",
            "record_type": "mortgage_lending_summary",
            "scope": scope,
            "year": 2022,
            "loans_originated": originated.get("count", 0),
            "loans_originated_amount": originated.get("sum", 0),
            "loans_denied": denied.get("count", 0),
            "loans_denied_amount": denied.get("sum", 0),
            "denial_rate": round(
                denied.get("count", 0) / max(originated.get("count", 0) + denied.get("count", 0), 1) * 100, 1
            ),
            "avg_loan_amount": round(
                originated.get("sum", 0) / max(originated.get("count", 1), 1)
            ),
        }

        # Query 2: Breakdown by loan type
        try:
            loan_type_params = {**params, "loan_types": "1,2,3,4"}
            lt_data = await fetch_json(HMDA_BASE, params=loan_type_params)
            lt_aggs = lt_data.get("aggregations", [])
            for lt in lt_aggs:
                code = lt.get("loan_types", "")
                label = LOAN_TYPE_LABELS.get(code, code)
                mortgage_entity[f"loans_{label}"] = lt.get("count", 0)
                mortgage_entity[f"loans_{label}_amount"] = lt.get("sum", 0)
        except Exception:
            pass  # Loan type breakdown is supplemental

        entities.append(mortgage_entity)

        if address_id:
            relationships.append({
                "source_id": address_id,
                "target_id": record_id,
                "type": "HAS_LENDING_DATA",
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
            data = await fetch_json(
                HMDA_BASE,
                params={"states": "GA", "counties": "13135", "years": "2022", "actions_taken": "1"},
                retries=1,
            )
            return "aggregations" in data
        except Exception:
            return False
