"""Graph query API endpoints."""

from __future__ import annotations

from fastapi import APIRouter

from app.database import neo4j_driver

router = APIRouter()


@router.post("/graph/path")
async def find_path(
    source_id: str,
    target_id: str,
    max_depth: int = 6,
) -> dict:
    """Find shortest path between two entities."""
    try:
        result = await neo4j_driver.find_path(source_id, target_id, max_depth)
        return result
    except Exception:
        return {"nodes": [], "relationships": []}
