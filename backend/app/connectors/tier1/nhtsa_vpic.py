"""NHTSA vPIC connector — VIN decoding and recalls.

API: https://vpic.nhtsa.dot.gov/api/ (free, no auth, no rate limit)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

VPIC_BASE = "https://vpic.nhtsa.dot.gov/api/vehicles"
RECALLS_BASE = "https://api.nhtsa.gov/recalls/recallsByVehicle"


class NHTSAConnector(BaseConnector):
    name = "nhtsa_vpic"
    description = "NHTSA vPIC — VIN decoding and recalls"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=10.0, burst_size=20)
    default_confidence = 0.95
    supported_input_types = [EntityType.VEHICLE]
    supported_output_types = [EntityType.VEHICLE]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        vin = entity.get("vin", "")
        if not vin or len(vin) < 11:
            return ConnectorResult(error="Valid VIN required (11+ chars)", source_name=self.name)

        cache_params = {"vin": vin}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        # Decode VIN
        try:
            data = await fetch_json(f"{VPIC_BASE}/DecodeVin/{vin}?format=json")
        except Exception as e:
            self.logger.error("NHTSA vPIC error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        results = data.get("Results", [])
        decoded: dict[str, str] = {}
        for item in results:
            variable = item.get("Variable", "")
            value = item.get("Value")
            if value and value.strip():
                decoded[variable] = value.strip()

        vehicle_entity = {
            "id": entity.get("id", str(uuid4())),
            "type": "VEHICLE",
            "vin": vin,
            "make": decoded.get("Make", ""),
            "model": decoded.get("Model", ""),
            "year": decoded.get("Model Year", ""),
            "body_type": decoded.get("Body Class", ""),
            "vehicle_class": decoded.get("Vehicle Type", ""),
            "plant_city": decoded.get("Plant City", ""),
            "plant_country": decoded.get("Plant Country", ""),
            "fuel_type": decoded.get("Fuel Type - Primary", ""),
            "engine_cylinders": decoded.get("Engine Number of Cylinders", ""),
            "displacement_l": decoded.get("Displacement (L)", ""),
        }

        # Check recalls
        make = decoded.get("Make", "")
        model = decoded.get("Model", "")
        year = decoded.get("Model Year", "")
        recalls = []
        if make and model and year:
            try:
                recall_data = await fetch_json(
                    RECALLS_BASE, params={"make": make, "model": model, "modelYear": year}
                )
                for r in recall_data.get("results", [])[:5]:
                    recalls.append({
                        "campaign_number": r.get("NHTSACampaignNumber", ""),
                        "component": r.get("Component", ""),
                        "summary": r.get("Summary", ""),
                        "consequence": r.get("Consequence", ""),
                    })
            except Exception:
                self.logger.debug("Recall lookup failed for %s %s %s", year, make, model)

        vehicle_entity["recalls"] = recalls
        vehicle_entity["recall_count"] = len(recalls)

        result_data = {"entities": [vehicle_entity], "decoded": decoded, "recalls": recalls}
        await set_cached(self.name, cache_params, result_data)
        return ConnectorResult(
            entities=[vehicle_entity], raw_data=result_data,
            source_name=self.name, confidence=self.default_confidence,
        )

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(f"{VPIC_BASE}/DecodeVin/1HGCG5655WA123456?format=json", retries=1)
            return True
        except Exception:
            return False
