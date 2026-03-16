"""Gwinnett Sheriff JAIL View connector — inmate records.

Source: https://www.gwinnettcountysheriff.com/smartwebclient/ (web scraping)
"""

from __future__ import annotations

import re
from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_text

JAIL_SEARCH = "https://www.gwinnettcountysheriff.com/smartwebclient/"


class GwinnettSheriffJailConnector(BaseConnector):
    name = "gwinnett_sheriff_jail"
    description = "Gwinnett Sheriff — inmate records"
    tier = 2
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=1.0, burst_size=2)
    default_confidence = 0.85
    supported_input_types = [EntityType.PERSON]
    supported_output_types = [EntityType.CASE]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        if entity.get("type") != "PERSON":
            return ConnectorResult(error="Requires PERSON entity", source_name=self.name)

        last_name = entity.get("last_name", "")
        first_name = entity.get("first_name", "")

        if not last_name or len(last_name.strip()) < 2:
            return ConnectorResult(error="Last name required", source_name=self.name)

        cache_key = {"last_name": last_name, "first_name": first_name}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            html = await fetch_text(
                JAIL_SEARCH,
                params={"lastName": last_name, "firstName": first_name},
            )
        except Exception as e:
            self.logger.error("Gwinnett Jail error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        entities = []
        relationships = []

        # Extract booking/charge info
        charge_matches = re.findall(
            r'(?:charge|offense)[^:]*:\s*([^<\n]+)',
            html,
            re.IGNORECASE,
        )
        booking_dates = re.findall(r'(\d{1,2}/\d{1,2}/\d{4})', html)

        for i, charge in enumerate(charge_matches[:10]):
            charge = charge.strip()
            if not charge or len(charge) < 3:
                continue

            case_id = str(uuid4())
            entities.append({
                "id": case_id,
                "type": "CASE",
                "case_number": f"JAIL-{uuid4().hex[:8].upper()}",
                "court_name": "Gwinnett County Sheriff",
                "court_type": "county",
                "case_type": "criminal",
                "charges": [charge],
                "booking_date": booking_dates[i] if i < len(booking_dates) else None,
            })

            if entity.get("id"):
                relationships.append({
                    "source_id": entity["id"], "target_id": case_id,
                    "type": "NAMED_IN_CASE",
                    "properties": {"sources": [self.name], "party_type": "defendant"},
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
            await fetch_text(JAIL_SEARCH, retries=1)
            return True
        except Exception:
            return False
