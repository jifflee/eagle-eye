"""FCC License View — broadcast and wireless licenses.

API: https://www.fcc.gov/reports-research/developers/license-view-api (free, no auth)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

FCC_BASE = "https://www.fcc.gov/api/license-view/basicSearch/getLicenses"


class FCCLicenseConnector(BaseConnector):
    name = "fcc_license"
    description = "FCC — broadcast/wireless licenses by name"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.85
    supported_input_types = [EntityType.PERSON, EntityType.BUSINESS]
    supported_output_types = [EntityType.BUSINESS]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        if entity.get("type") == "PERSON":
            search = entity.get("full_name") or entity.get("last_name", "")
        elif entity.get("type") == "BUSINESS":
            search = entity.get("name", "")
        else:
            return ConnectorResult(error="Requires PERSON or BUSINESS", source_name=self.name)

        if not search or len(search) < 3:
            return ConnectorResult(error="Search term too short", source_name=self.name)

        cache_key = {"query": search}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(entities=cached.get("entities", []),
                                   raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        try:
            data = await fetch_json(FCC_BASE, params={"searchValue": search, "format": "json", "limit": "10"})
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        licenses = data.get("Licenses", {}).get("License", [])
        if isinstance(licenses, dict):
            licenses = [licenses]

        entities = []
        for lic in licenses[:10]:
            ent_id = str(uuid4())
            entities.append({
                "id": ent_id, "type": "BUSINESS",
                "name": lic.get("licName", ""),
                "fcc_license_id": lic.get("licenseID", ""),
                "call_sign": lic.get("callsign", ""),
                "service_type": lic.get("serviceDesc", ""),
                "status": lic.get("statusDesc", ""),
                "expiration_date": lic.get("expiredDate", ""),
                "entity_type_business": "FCC Licensee",
            })

        result_data = {"entities": entities}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, raw_data=result_data,
                               source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(FCC_BASE, params={"searchValue": "test", "format": "json", "limit": "1"}, retries=1)
            return True
        except Exception:
            return False
