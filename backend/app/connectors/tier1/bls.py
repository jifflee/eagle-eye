"""BLS connector — employment and wage data by state/area.

API: https://api.bls.gov/publicAPI/v2/timeseries/data/
Free, no auth required for v2 (10 series per query, 25 queries/day).
Queries unemployment rate, employment count, and average weekly wages.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

BLS_API = "https://api.bls.gov/publicAPI/v2/timeseries/data/"

# State FIPS to BLS LAUS series prefix mapping
# LASST{fips}0000000000003 = unemployment rate
# LASST{fips}0000000000006 = employment count
STATE_FIPS = {
    "AL": "01", "AK": "02", "AZ": "04", "AR": "05", "CA": "06",
    "CO": "08", "CT": "09", "DE": "10", "FL": "12", "GA": "13",
    "HI": "15", "ID": "16", "IL": "17", "IN": "18", "IA": "19",
    "KS": "20", "KY": "21", "LA": "22", "ME": "23", "MD": "24",
    "MA": "25", "MI": "26", "MN": "27", "MS": "28", "MO": "29",
    "MT": "30", "NE": "31", "NV": "32", "NH": "33", "NJ": "34",
    "NM": "35", "NY": "36", "NC": "37", "ND": "38", "OH": "39",
    "OK": "40", "OR": "41", "PA": "42", "RI": "44", "SC": "45",
    "SD": "46", "TN": "47", "TX": "48", "UT": "49", "VT": "50",
    "VA": "51", "WA": "53", "WV": "54", "WI": "55", "WY": "56",
}


def _safe_float(val: str) -> float | None:
    try:
        return float(val) if val else None
    except (ValueError, TypeError):
        return None


def _safe_int(val: str) -> int | None:
    try:
        return int(float(val)) if val else None
    except (ValueError, TypeError):
        return None


class BLSConnector(BaseConnector):
    name = "bls"
    description = "BLS — unemployment, employment, and wages by state"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=1.0, burst_size=3)
    default_confidence = 0.95
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.FINANCIAL_RECORD]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        """Fetch employment and wage data for the state of an address."""
        state = entity.get("state", "GA").upper()
        fips = STATE_FIPS.get(state)
        if not fips:
            return ConnectorResult(error=f"Unknown state: {state}", source_name=self.name)

        cache_key = {"state": state, "source": "bls"}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        # BLS series IDs for state-level data
        unemp_rate_id = f"LASST{fips}0000000000003"  # Unemployment rate
        employment_id = f"LASST{fips}0000000000006"  # Employment level

        try:
            data = await fetch_json(
                BLS_API,
                method="POST",
                json_body={
                    "seriesid": [unemp_rate_id, employment_id],
                    "latest": True,
                },
                retries=2,
            )
        except Exception as e:
            return ConnectorResult(error=f"BLS API error: {e}", source_name=self.name)

        if data.get("status") != "REQUEST_SUCCEEDED":
            return ConnectorResult(
                error=f"BLS: {data.get('message', 'Unknown error')}", source_name=self.name,
            )

        entities = []
        relationships = []
        address_id = entity.get("id")

        record_id = str(uuid4())
        record: dict[str, Any] = {
            "id": record_id,
            "type": "FINANCIAL_RECORD",
            "record_type": "employment_data",
            "scope": f"{state} Statewide",
        }

        for series in data.get("Results", {}).get("series", []):
            sid = series.get("seriesID", "")
            latest = series.get("data", [{}])[0] if series.get("data") else {}
            value = latest.get("value", "")
            period = f"{latest.get('periodName', '')} {latest.get('year', '')}".strip()

            if sid == unemp_rate_id:
                record["unemployment_rate"] = _safe_float(value)
                record["unemployment_period"] = period
            elif sid == employment_id:
                record["employment_count"] = _safe_int(value)
                record["employment_period"] = period

        record["year"] = int(latest.get("year", 0)) if latest.get("year") else None
        entities.append(record)

        if address_id:
            relationships.append({
                "source_id": address_id,
                "target_id": record_id,
                "type": "HAS_EMPLOYMENT_DATA",
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
                BLS_API,
                method="POST",
                json_body={"seriesid": ["LASST130000000000003"], "latest": True},
                retries=1,
            )
            return data.get("status") == "REQUEST_SUCCEEDED"
        except Exception:
            return False
