"""Overpass API — all POIs/businesses near an address via OpenStreetMap.

API: https://overpass-api.de/ (free, no auth)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

OVERPASS_URL = "https://overpass-api.de/api/interpreter"


class OverpassConnector(BaseConnector):
    name = "overpass_osm"
    description = "OpenStreetMap Overpass — POIs near address"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=0.5, burst_size=2)
    default_confidence = 0.75
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.BUSINESS]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        lat = entity.get("latitude")
        lon = entity.get("longitude")
        if not lat or not lon:
            return ConnectorResult(error="Coordinates required", source_name=self.name)

        cache_key = {"lat": round(float(lat), 4), "lon": round(float(lon), 4)}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(entities=cached.get("entities", []),
                                   raw_data=cached, source_name=self.name, confidence=self.default_confidence)

        # Query all named amenities/shops/offices within 500m
        query = f"""
        [out:json][timeout:15];
        (
          node["name"](around:500,{lat},{lon});
          way["name"]["building"](around:500,{lat},{lon});
        );
        out center 20;
        """

        try:
            data = await fetch_json(OVERPASS_URL, params={"data": query})
        except Exception as e:
            return ConnectorResult(error=str(e), source_name=self.name)

        elements = data.get("elements", [])
        entities = []
        seen: set[str] = set()

        for el in elements[:20]:
            tags = el.get("tags", {})
            name = tags.get("name", "")
            if not name or name in seen:
                continue
            seen.add(name)

            biz_id = str(uuid4())
            amenity = tags.get("amenity") or tags.get("shop") or tags.get("office") or tags.get("tourism") or ""
            entities.append({
                "id": biz_id, "type": "BUSINESS",
                "name": name,
                "entity_type_business": amenity,
                "address": tags.get("addr:street", ""),
                "phone": tags.get("phone", ""),
                "website": tags.get("website", ""),
                "opening_hours": tags.get("opening_hours", ""),
                "latitude": el.get("lat") or el.get("center", {}).get("lat"),
                "longitude": el.get("lon") or el.get("center", {}).get("lon"),
                "osm_type": el.get("type"),
                "osm_id": el.get("id"),
            })

        result_data = {"entities": entities}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, raw_data=result_data,
                               source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(OVERPASS_URL, params={"data": "[out:json];node(1);out;"}, retries=1)
            return True
        except Exception:
            return False
