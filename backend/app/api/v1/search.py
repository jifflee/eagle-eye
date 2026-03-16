"""Search API endpoint."""

from __future__ import annotations

import logging

from fastapi import APIRouter

from app.database import neo4j_driver
from app.models.schemas import SearchRequest, SearchResponse, SearchResultItem

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/search", response_model=SearchResponse)
async def search_entities(request: SearchRequest) -> SearchResponse:
    """Full-text search across all entities."""
    try:
        results = await neo4j_driver.fulltext_search(
            query_text=request.query,
            entity_types=request.entity_types,
            limit=request.limit,
        )
    except Exception:
        logger.warning("Neo4j unavailable, returning empty results")
        results = []

    items = []
    for r in results:
        props = r.get("properties", {})
        labels = r.get("labels", [])

        # Import here to avoid circular imports
        from app.api.v1.address import _labels_to_entity_type, _entity_label

        entity_type = _labels_to_entity_type(labels)
        label = _entity_label(entity_type, props)

        items.append(
            SearchResultItem(
                entity_id=props.get("id", ""),
                entity_type=entity_type,
                label=label,
                relevance_score=r.get("score", 0.0),
                matched_fields=list(props.keys())[:3],
            )
        )

    return SearchResponse(
        results=items,
        total=len(items),
        limit=request.limit,
        offset=request.offset,
    )
