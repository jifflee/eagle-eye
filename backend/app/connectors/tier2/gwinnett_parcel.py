"""Gwinnett County Property & Tax — owner, value, zoning via ArcGIS REST API.

API: https://services3.arcgis.com/RfpmnkSAQleRbndX/arcgis/rest/services/Property_and_Tax/FeatureServer
Free, no auth. Official Gwinnett County GIS service.

Layers:
  0 = Parcels (geometry)
  3 = Tax Master Table (owner, value, zoning, deed history)
  4 = Tax Owner Address Table (owner + mailing address)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

# Gwinnett County Property & Tax FeatureServer — Tax Master Table
TAX_MASTER_URL = "https://services3.arcgis.com/RfpmnkSAQleRbndX/arcgis/rest/services/Property_and_Tax/FeatureServer/3/query"


class GwinnettParcelConnector(BaseConnector):
    name = "gwinnett_parcel"
    description = "Gwinnett County — property owner, value, zoning"
    tier = 2
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=2.0, burst_size=5)
    default_confidence = 0.90
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.PROPERTY, EntityType.PERSON]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        street = entity.get("street", "")
        if not street or len(street) < 3:
            return ConnectorResult(error="Street address required", source_name=self.name)

        search_term = street.upper().strip()

        cache_key = {"street": search_term}
        cached = await get_cached(self.name, cache_key)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            data = await fetch_json(TAX_MASTER_URL, params={
                "where": f"UPPER(LOCADDR) LIKE UPPER('%{search_term.replace(chr(39), chr(39)+chr(39))}%')",
                "outFields": "*",
                "resultRecordCount": "5",
                "f": "json",
            })
        except Exception as e:
            self.logger.error("Gwinnett Property error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        features = data.get("features", [])
        if not features:
            return ConnectorResult(entities=[], relationships=[], raw_data={"features": []},
                                   source_name=self.name, confidence=self.default_confidence)

        entities = []
        relationships = []
        address_id = entity.get("id")

        for feature in features[:5]:
            attrs = feature.get("attributes", {})
            owner_name = attrs.get("OWNER1", "")
            owner2 = attrs.get("OWNER2", "")

            # PROPERTY entity
            prop_id = str(uuid4())
            entities.append({
                "id": prop_id, "type": "PROPERTY",
                "apn": attrs.get("RPIN", attrs.get("PIN", "")),
                "owner_name": owner_name,
                "address": attrs.get("LOCADDR", ""),
                "city": attrs.get("LOCCITY", ""),
                "zip": attrs.get("LOCZIP", ""),
                "assessed_value": _safe_num(attrs.get("TOTVAL1")),
                "land_value": _safe_num(attrs.get("LANDVAL1")),
                "dwelling_value": _safe_num(attrs.get("DWLGVAL1")),
                "tax_amount": _safe_num(attrs.get("TAXTOT1")),
                "zoning_class": attrs.get("ZONING", ""),
                "zoning_description": attrs.get("ZONEDESC", ""),
                "property_class": attrs.get("PCDESC", ""),
                "legal_acres": attrs.get("LEGALAC", ""),
                "grantor1": attrs.get("GRANTOR1", ""),
                "grantor2": attrs.get("GRANTOR2", ""),
                "grantor3": attrs.get("GRANTOR3", ""),
            })

            if address_id:
                relationships.append({
                    "source_id": address_id, "target_id": prop_id,
                    "type": "OWNS_PROPERTY", "properties": {"sources": [self.name]},
                })

            # PERSON — current owner
            if owner_name:
                person_id = str(uuid4())
                parts = owner_name.split()
                entities.append({
                    "id": person_id, "type": "PERSON",
                    "full_name": owner_name,
                    "first_name": parts[1] if len(parts) > 1 else "",
                    "last_name": parts[0] if parts else "",
                    "mail_address": attrs.get("MAILADDR", ""),
                    "mail_city": attrs.get("MAILCITY", ""),
                    "mail_state": attrs.get("MAILSTAT", ""),
                    "mail_zip": attrs.get("MAILZIP", ""),
                })
                relationships.append({"source_id": person_id, "target_id": prop_id,
                                      "type": "OWNS_PROPERTY", "properties": {"sources": [self.name]}})
                if address_id:
                    relationships.append({"source_id": person_id, "target_id": address_id,
                                          "type": "LIVES_AT", "properties": {"sources": [self.name]}})

            # PERSON — second owner
            if owner2 and len(owner2.strip()) > 2:
                p2_id = str(uuid4())
                p2 = owner2.split()
                entities.append({"id": p2_id, "type": "PERSON", "full_name": owner2,
                                 "first_name": p2[1] if len(p2) > 1 else "", "last_name": p2[0] if p2 else ""})
                relationships.append({"source_id": p2_id, "target_id": prop_id,
                                      "type": "OWNS_PROPERTY", "properties": {"sources": [self.name]}})

            # PERSON — previous owners from deed chain
            for gf in ["GRANTOR1", "GRANTOR2", "GRANTOR3"]:
                grantor = (attrs.get(gf) or "").strip()
                if grantor and len(grantor) > 3:
                    g_id = str(uuid4())
                    entities.append({"id": g_id, "type": "PERSON", "full_name": grantor,
                                     "first_name": "", "last_name": grantor, "previous_owner": True})
                    relationships.append({"source_id": g_id, "target_id": prop_id,
                                          "type": "OWNS_PROPERTY",
                                          "properties": {"sources": [self.name], "relationship_subtype": "previous_owner"}})

        result_data = {"entities": entities, "relationships": relationships}
        await set_cached(self.name, cache_key, result_data)
        return ConnectorResult(entities=entities, relationships=relationships,
                               raw_data=result_data, source_name=self.name, confidence=self.default_confidence)

    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        return await self.discover(entity)

    async def validate(self) -> bool:
        try:
            await fetch_json(TAX_MASTER_URL, params={"where": "1=1", "resultRecordCount": "1", "f": "json"}, retries=1)
            return True
        except Exception:
            return False


def _safe_num(val: Any) -> float | None:
    try:
        return float(str(val).strip()) if val is not None else None
    except (ValueError, TypeError):
        return None
