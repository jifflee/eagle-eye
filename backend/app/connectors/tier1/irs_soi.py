"""IRS Statistics of Income connector — income demographics by ZIP code.

Source: IRS SOI Tax Stats (https://www.irs.gov/statistics/soi-tax-stats)
Static CSV, cached locally with ETag-based diff checking.
Data: tax year 2019, income brackets, salary/wage totals, filing patterns per ZIP.
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

IRS_CSV_URL = "https://www.irs.gov/pub/irs-soi/19zpallagi.csv"
DATA_DIR = Path(__file__).resolve().parents[3] / "data"
LOCAL_CSV = DATA_DIR / "irs_soi_zip.csv"
LOCAL_ETAG = DATA_DIR / "irs_soi_zip.etag"

# agi_stub: 1=<$25k, 2=$25-50k, 3=$50-75k, 4=$75-100k, 5=$100-200k, 6=$200k+
AGI_LABELS = {
    "1": "Under $25,000",
    "2": "$25,000–$49,999",
    "3": "$50,000–$74,999",
    "4": "$75,000–$99,999",
    "5": "$100,000–$199,999",
    "6": "$200,000 or more",
}


async def _sync_csv() -> str:
    """Download IRS SOI CSV if missing or changed (ETag-based)."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    old_etag = LOCAL_ETAG.read_text().strip() if LOCAL_ETAG.exists() else ""

    try:
        client = get_client()
        headers = {}
        if old_etag:
            headers["If-None-Match"] = old_etag

        response = await client.get(IRS_CSV_URL, headers=headers)

        if response.status_code == 304:
            logger.info("IRS SOI CSV unchanged (ETag match)")
            return LOCAL_CSV.read_text()

        response.raise_for_status()
        csv_text = response.text

        LOCAL_CSV.write_text(csv_text)
        new_etag = response.headers.get("etag", "")
        if new_etag:
            LOCAL_ETAG.write_text(new_etag)

        logger.info("IRS SOI CSV updated. ETag: %s", new_etag[:20])
        return csv_text

    except Exception as e:
        if LOCAL_CSV.exists():
            logger.warning("Failed to check upstream IRS CSV (%s), using local cache", e)
            return LOCAL_CSV.read_text()
        raise


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


def _parse_zip_data(csv_text: str, zipcode: str) -> list[dict[str, Any]]:
    """Extract all AGI bracket rows for a given ZIP code."""
    reader = csv.DictReader(io.StringIO(csv_text))
    rows = []
    for row in reader:
        if row.get("zipcode") == zipcode:
            rows.append(row)
    return rows


class IRSSOIConnector(BaseConnector):
    name = "irs_soi"
    description = "IRS SOI — income demographics by ZIP code"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=5.0, burst_size=10)
    default_confidence = 0.90
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.FINANCIAL_RECORD]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        """Fetch income demographics for the ZIP code of an address."""
        zipcode = entity.get("zip", "")
        if not zipcode or len(zipcode) < 5:
            return ConnectorResult(error="ZIP code required", source_name=self.name)

        zipcode = zipcode[:5]  # Use 5-digit ZIP

        cache_key = {"zip": zipcode, "source": "irs_soi"}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            csv_text = await _sync_csv()
        except Exception as e:
            return ConnectorResult(error=f"Failed to load IRS data: {e}", source_name=self.name)

        rows = _parse_zip_data(csv_text, zipcode)
        if not rows:
            return ConnectorResult(error=f"No IRS data for ZIP {zipcode}", source_name=self.name)

        entities = []
        relationships = []
        address_id = entity.get("id")

        # Aggregate across all AGI brackets
        total_returns = 0
        total_agi = 0.0
        total_salaries = 0.0
        bracket_breakdown = []

        for row in rows:
            stub = row.get("agi_stub", "")
            n_returns = _safe_int(row.get("N1")) or 0
            agi = _safe_float(row.get("A00100")) or 0.0  # AGI in thousands
            salaries = _safe_float(row.get("A00200")) or 0.0  # Salaries in thousands
            n_dependents = _safe_int(row.get("N2")) or 0
            n_elderly = _safe_int(row.get("ELDERLY")) or 0

            total_returns += n_returns
            total_agi += agi
            total_salaries += salaries

            bracket_breakdown.append({
                "bracket": AGI_LABELS.get(stub, stub),
                "returns": n_returns,
                "agi_thousands": agi,
                "salaries_thousands": salaries,
                "dependents": n_dependents,
                "elderly_returns": n_elderly,
            })

        record_id = str(uuid4())
        income_entity = {
            "id": record_id,
            "type": "FINANCIAL_RECORD",
            "record_type": "income_demographics",
            "scope": f"ZIP {zipcode}",
            "year": 2019,
            "total_tax_returns": total_returns,
            "total_agi_thousands": round(total_agi),
            "total_salaries_thousands": round(total_salaries),
            "avg_agi_per_return": round(total_agi / max(total_returns, 1) * 1000),
            "avg_salary_per_return": round(total_salaries / max(total_returns, 1) * 1000),
            "bracket_breakdown": bracket_breakdown,
        }
        entities.append(income_entity)

        if address_id:
            relationships.append({
                "source_id": address_id,
                "target_id": record_id,
                "type": "HAS_INCOME_DATA",
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
            csv_text = await _sync_csv()
            return len(csv_text) > 1000
        except Exception:
            return False
