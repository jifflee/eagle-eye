"""SEC EDGAR connector — corporate filings and officers.

API: https://data.sec.gov/ (free, no auth, requires User-Agent)
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from app.cache.redis_cache import get_cached, set_cached
from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType
from app.utils.http_client import fetch_json

EDGAR_BASE = "https://efts.sec.gov/LATEST"
EDGAR_DATA = "https://data.sec.gov"
SEC_HEADERS = {"User-Agent": "EagleEye/0.1.0 (osint@eagleeye.dev)"}


class SECEdgarConnector(BaseConnector):
    name = "sec_edgar"
    description = "SEC EDGAR — corporate filings and officers"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=10.0, burst_size=10)
    default_confidence = 0.90
    supported_input_types = [EntityType.PERSON, EntityType.BUSINESS, EntityType.ADDRESS]
    supported_output_types = [EntityType.BUSINESS, EntityType.PERSON]

    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        entity_type = entity.get("type", "")
        search_term = ""

        if entity_type == "PERSON":
            search_term = entity.get("full_name") or f"{entity.get('first_name', '')} {entity.get('last_name', '')}"
        elif entity_type == "BUSINESS":
            search_term = entity.get("name", "")
        elif entity_type == "ADDRESS":
            search_term = entity.get("street", "")

        if not search_term or len(search_term.strip()) < 3:
            return ConnectorResult(error="Search term too short", source_name=self.name)

        cache_params = {"query": search_term.strip()}
        cached = await get_cached(self.name, cache_params)
        if cached:
            return ConnectorResult(
                entities=cached.get("entities", []),
                relationships=cached.get("relationships", []),
                raw_data=cached, source_name=self.name, confidence=self.default_confidence,
            )

        try:
            data = await fetch_json(
                f"{EDGAR_BASE}/search-index",
                params={"q": search_term, "dateRange": "custom", "startdt": "2015-01-01", "forms": "10-K,10-Q,8-K"},
                headers=SEC_HEADERS,
            )
        except Exception as e:
            self.logger.error("SEC EDGAR error: %s", e)
            return ConnectorResult(error=str(e), source_name=self.name)

        hits = data.get("hits", {}).get("hits", [])
        entities = []
        relationships = []

        seen_companies: set[str] = set()
        for hit in hits[:15]:
            source = hit.get("_source", {})
            company_name = source.get("entity_name", "")
            cik = source.get("entity_id", "")

            if not company_name or company_name in seen_companies:
                continue
            seen_companies.add(company_name)

            biz_id = str(uuid4())
            entities.append({
                "id": biz_id,
                "type": "BUSINESS",
                "name": company_name,
                "legal_name": company_name,
                "cik": cik,
                "entity_type_business": source.get("entity_type", ""),
                "latest_filing": source.get("file_date", ""),
                "form_type": source.get("form_type", ""),
            })

            if entity.get("id"):
                rel_type = "OWNS_BUSINESS" if entity_type == "PERSON" else "AFFILIATED_WITH"
                relationships.append({
                    "source_id": entity["id"], "target_id": biz_id,
                    "type": rel_type,
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
            await fetch_json(
                f"{EDGAR_BASE}/search-index",
                params={"q": "test", "forms": "10-K"},
                headers=SEC_HEADERS, retries=1,
            )
            return True
        except Exception:
            return False
