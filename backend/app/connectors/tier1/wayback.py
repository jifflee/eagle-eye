"""Wayback Machine CDX API — archived website snapshots.

API: https://web.archive.org/cdx/search/cdx (free, no auth)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

CDX_BASE = "https://web.archive.org/cdx/search/cdx"


class WaybackConnector(BaseConnector):
    name = "wayback"
    description = "Wayback Machine — archived websites"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=0.8, burst_size=2)
    default_confidence = 0.70
    supported_input_types = [EntityType.BUSINESS]
    supported_output_types = [EntityType.SOCIAL_PROFILE]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        website = entity.get("website") or entity.get("domain", "")
        name = entity.get("name", "")

        if not website and name:
            # Try to guess domain from business name
            slug = name.lower().replace(" ", "").replace(",", "").replace(".", "")[:20]
            website = f"{slug}.com"

        if not website:
            return ConnectorResult(error="Website or business name required", source_name=self.name)

        cache_key = {"url": website}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(entities=cached.get("entities", []),
                                   raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        try:
            data = await fetch_json(CDX_BASE, params={
                "url": website, "output": "json", "limit": "5",
                "fl": "timestamp,original,statuscode,mimetype",
                "filter": "statuscode:200",
            })
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        if not data or len(data) < 2:
            return ConnectorResult(entities=[], raw_data={"snapshots": []},
                                   source_name=self.name, confidence=self.default_confidence)

        entities = []
        # First row is headers, rest are data
        for row in data[1:6]:
            timestamp = row[0] if len(row) > 0 else ""
            url = row[1] if len(row) > 1 else ""
            profile_id = str(uuid4())
            entities.append({
                "id": profile_id, "type": "SOCIAL_PROFILE",
                "platform": "Wayback Machine",
                "username": website,
                "profile_url": f"https://web.archive.org/web/{timestamp}/{url}",
                "snapshot_date": f"{timestamp[:4]}-{timestamp[4:6]}-{timestamp[6:8]}" if len(timestamp) >= 8 else "",
            })

        result_data = {"entities": entities}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, raw_data=result_data,
                               source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(CDX_BASE, params={"url": "example.com", "output": "json", "limit": "1"}, retries=1)
            return True
        except Exception:
            return False
