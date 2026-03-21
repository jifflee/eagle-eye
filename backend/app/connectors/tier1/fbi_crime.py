"""FBI Crime Data connector — crime statistics by state from UCR data.

Primary source: CORGIS UCR state_crime.csv (static, cached locally).
The FBI CDE API (cde.ucr.cjis.gov) is behind AWS API Gateway auth and
no longer accessible via data.gov API keys. This connector uses the
CORGIS mirror of UCR data with local caching and ETag-based diff checking.

Data covers 1960-2019 with violent and property crime rates/totals per state.
"""

from __future__ import annotations

import csv
import io
import logging
from pathlib import Path
from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import get_client

logger = logging.getLogger(__name__)

CORGIS_CSV_URL = "https://corgis-edu.github.io/corgis/datasets/csv/state_crime/state_crime.csv"
DATA_DIR = Path(__file__).resolve().parents[3] / "data"
LOCAL_CSV = DATA_DIR / "state_crime.csv"
LOCAL_ETAG = DATA_DIR / "state_crime.etag"

# Map full state names to abbreviations for lookup
STATE_NAMES = {
    "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas",
    "CA": "California", "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware",
    "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho",
    "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
    "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
    "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi",
    "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
    "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
    "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
    "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
    "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah",
    "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
    "WI": "Wisconsin", "WY": "Wyoming",
}
ABBR_TO_NAME = STATE_NAMES
NAME_TO_ABBR = {v: k for k, v in STATE_NAMES.items()}


async def _sync_csv() -> str:
    """Download CSV if missing or changed (ETag-based diff check). Returns CSV text."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    # If we have a local copy, check if upstream changed via ETag
    old_etag = LOCAL_ETAG.read_text().strip() if LOCAL_ETAG.exists() else ""

    try:
        client = get_client()
        headers = {}
        if old_etag:
            headers["If-None-Match"] = old_etag

        response = await client.get(CORGIS_CSV_URL, headers=headers)

        if response.status_code == 304:
            # Not modified — use local cache
            logger.info("FBI crime CSV unchanged (ETag match)")
            return LOCAL_CSV.read_text()

        response.raise_for_status()
        csv_text = response.text

        # Save locally
        LOCAL_CSV.write_text(csv_text)
        new_etag = response.headers.get("etag", "")
        if new_etag:
            LOCAL_ETAG.write_text(new_etag)

        old_lines = 0
        if old_etag:
            old_lines = sum(1 for _ in LOCAL_CSV.open()) if LOCAL_CSV.exists() else 0
        new_lines = csv_text.count("\n")
        logger.info(
            "FBI crime CSV updated: %d rows (was %d). ETag: %s",
            new_lines, old_lines, new_etag[:20],
        )
        return csv_text

    except Exception as e:
        # Network error — fall back to local cache
        if LOCAL_CSV.exists():
            logger.warning("Failed to check upstream CSV (%s), using local cache", e)
            return LOCAL_CSV.read_text()
        raise


def _parse_csv(csv_text: str, state_name: str) -> list[dict[str, Any]]:
    """Parse CORGIS state_crime.csv and return rows for the given state."""
    reader = csv.DictReader(io.StringIO(csv_text))
    rows = []
    for row in reader:
        if row.get("State") == state_name:
            rows.append(row)
    return rows


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


class FBICrimeConnector(BaseConnector):
    name = "fbi_crime"
    description = "FBI UCR — crime statistics by state (CORGIS mirror)"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=5.0, burst_size=10)
    default_confidence = 0.90
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.CRIME_RECORD]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        """Fetch crime statistics for the state of an address."""
        state_abbr = entity.get("state", "GA").upper()
        state_name = ABBR_TO_NAME.get(state_abbr)
        if not state_name:
            return ConnectorResult(error=f"Unknown state: {state_abbr}", source_name=self.name)

        cache_params = {"state": state_abbr, "source": "corgis"}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            csv_text = await _sync_csv()
        except Exception as e:
            return ConnectorResult(error=f"Failed to load crime data: {e}", source_name=self.name)

        rows = _parse_csv(csv_text, state_name)
        if not rows:
            return ConnectorResult(error=f"No crime data for {state_name}", source_name=self.name)

        entities = []
        relationships = []
        address_id = entity.get("id")

        # Return last 5 years of data
        for row in rows[-5:]:
            crime_id = str(uuid4())
            year = row.get("Year", "")

            crime_entity = {
                "id": crime_id,
                "type": "CRIME_RECORD",
                "incident_type": "annual_summary",
                "jurisdiction": f"{state_name} Statewide",
                "description": f"UCR crime summary for {state_name} {year}",
                "year": _safe_int(year),
                "population": _safe_int(row.get("Data.Population")),
                # Rates (per 100k population)
                "violent_crime_rate": _safe_float(row.get("Data.Rates.Violent.All")),
                "property_crime_rate": _safe_float(row.get("Data.Rates.Property.All")),
                "murder_rate": _safe_float(row.get("Data.Rates.Violent.Murder")),
                "rape_rate": _safe_float(row.get("Data.Rates.Violent.Rape")),
                "robbery_rate": _safe_float(row.get("Data.Rates.Violent.Robbery")),
                "assault_rate": _safe_float(row.get("Data.Rates.Violent.Assault")),
                "burglary_rate": _safe_float(row.get("Data.Rates.Property.Burglary")),
                "larceny_rate": _safe_float(row.get("Data.Rates.Property.Larceny")),
                "motor_vehicle_theft_rate": _safe_float(row.get("Data.Rates.Property.Motor")),
                # Totals
                "violent_crime": _safe_int(row.get("Data.Totals.Violent.All")),
                "property_crime": _safe_int(row.get("Data.Totals.Property.All")),
                "homicide": _safe_int(row.get("Data.Totals.Violent.Murder")),
                "rape": _safe_int(row.get("Data.Totals.Violent.Rape")),
                "robbery": _safe_int(row.get("Data.Totals.Violent.Robbery")),
                "aggravated_assault": _safe_int(row.get("Data.Totals.Violent.Assault")),
                "burglary": _safe_int(row.get("Data.Totals.Property.Burglary")),
                "larceny": _safe_int(row.get("Data.Totals.Property.Larceny")),
                "motor_vehicle_theft": _safe_int(row.get("Data.Totals.Property.Motor")),
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
            csv_text = await _sync_csv()
            return len(csv_text) > 1000
        except Exception:
            return False
