"""FDIC BankFind — bank branches and financial data.

API: https://banks.data.fdic.gov/ (free, no auth)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

FDIC_BASE = "https://api.fdic.gov/banks"


class FDICBankFindConnector(BaseConnector):
    name = "fdic_bankfind"
    description = "FDIC — bank branches near address"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.85
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.BUSINESS]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        city = entity.get("city", "")
        state = entity.get("state", "")
        if not city or not state:
            return ConnectorResult(error="City and state required", source_name=self.name)

        cache_key = {"city": city, "state": state}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(entities=cached.get("entities", []),
                                   raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        try:
            data = await fetch_json(f"{FDIC_BASE}/locations", params={
                "filters": f"STALP:{state} AND CITY:{city}",
                "fields": "INSTNAME,OFFNAME,STADDR,CITY,STALP,ZIP,MAINOFF",
                "limit": "10", "sort_by": "INSTNAME", "sort_order": "ASC",
            })
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        locations = data.get("data", [])
        entities = []

        for loc in locations[:10]:
            props = loc.get("data", {})
            biz_id = str(uuid4())
            entities.append({
                "id": biz_id, "type": "BUSINESS",
                "name": props.get("INSTNAME", ""),
                "branch_name": props.get("OFFNAME", ""),
                "address": props.get("STADDR", ""),
                "city": props.get("CITY", ""),
                "state": props.get("STALP", ""),
                "zip": props.get("ZIP", ""),
                "entity_type_business": "Bank",
                "fdic_cert": props.get("UNINUMBR"),
                "main_office": props.get("MAINOFF") == "1",
            })

        result_data = {"entities": entities}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, raw_data=result_data,
                               source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(f"{FDIC_BASE}/locations", params={"filters": "STALP:GA", "limit": "1"}, retries=1)
            return True
        except Exception:
            return False
