"""Gwinnett County ArcGIS connector — parcel data via REST API.

API: https://gcgis-gwinnettcountyga.hub.arcgis.com/ (free, no auth)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

# Gwinnett County Parcels FeatureServer
PARCELS_URL = "https://services.arcgis.com/9bBUMFVKJMKlBLl0/arcgis/rest/services/Parcels/FeatureServer/0/query"


class GwinnettParcelConnector(BaseConnector):
    name = "gwinnett_parcel"
    description = "Gwinnett County ArcGIS — parcel data"
    tier = 2
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.85
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.PROPERTY, EntityType.PERSON]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        lat = entity.get("latitude")
        lon = entity.get("longitude")
        street = entity.get("street", "")

        if not ((lat and lon) or street):
            return ConnectorResult(error="Requires coordinates or street address", source_name=self.name)

        cache_key = {"lat": lat, "lon": lon, "street": street}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        params: dict[str, Any] = {
            "outFields": "*",
            "returnGeometry": "false",
            "f": "json",
            "resultRecordCount": "5",
        }

        if lat and lon:
            params["geometry"] = f"{lon},{lat}"
            params["geometryType"] = "esriGeometryPoint"
            params["spatialRel"] = "esriSpatialRelIntersects"
            params["inSR"] = "4326"
            params["where"] = "1=1"
        else:
            params["where"] = f"UPPER(SITUS_ADDR) LIKE UPPER('%{street.replace("'", "''")}%')"

        try:
            data = await fetch_json(PARCELS_URL, params=params)
        except Exception as e:
            self.logger.error("Gwinnett Parcel error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        features = data.get("features", [])
        entities = []
        relationships = []
        address_id = entity.get("id")

        for feature in features[:5]:
            attrs = feature.get("attributes", {})
            prop_id = str(uuid4())
            owner_name = attrs.get("OWNER", "") or attrs.get("OWNER_NAME", "")

            entities.append({
                "id": prop_id,
                "type": "PROPERTY",
                "apn": attrs.get("PARCEL_ID", ""),
                "owner_name": owner_name,
                "assessed_value": attrs.get("TOTAL_ASSESSED", attrs.get("ASSESSED_VALUE")),
                "market_value": attrs.get("FAIR_MARKET_VALUE", attrs.get("MARKET_VALUE")),
                "zoning_class": attrs.get("ZONING", ""),
                "land_use": attrs.get("LAND_USE", ""),
                "square_footage": attrs.get("TOTAL_SQFT", attrs.get("HEATED_SQFT")),
                "lot_size": attrs.get("ACREAGE", attrs.get("ACRES")),
                "year_built": attrs.get("YEAR_BUILT"),
                "address": attrs.get("SITUS_ADDR", ""),
                "city": attrs.get("SITUS_CITY", ""),
            })

            if address_id:
                relationships.append({
                    "source_id": address_id, "target_id": prop_id,
                    "type": "OWNS_PROPERTY",
                    "properties": {"sources": [self.name]},
                })

            # Create person entity for owner
            if owner_name:
                person_id = str(uuid4())
                name_parts = owner_name.split()
                entities.append({
                    "id": person_id,
                    "type": "PERSON",
                    "full_name": owner_name,
                    "first_name": name_parts[0] if name_parts else "",
                    "last_name": name_parts[-1] if len(name_parts) > 1 else name_parts[0] if name_parts else "",
                })
                relationships.append({
                    "source_id": person_id, "target_id": prop_id,
                    "type": "OWNS_PROPERTY",
                    "properties": {"sources": [self.name]},
                })
                if address_id:
                    relationships.append({
                        "source_id": person_id, "target_id": address_id,
                        "type": "LIVES_AT",
                        "properties": {"sources": [self.name], "verified": False},
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
            await fetch_json(PARCELS_URL, params={"where": "1=1", "resultRecordCount": "1", "f": "json"}, retries=1)
            return True
        except Exception:
            return False
