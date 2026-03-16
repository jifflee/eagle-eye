from fastapi import APIRouter

router = APIRouter()


@router.get("/entity/{entity_id}")
async def get_entity(entity_id: str) -> dict[str, str]:
    """Get single entity with all relationships and provenance."""
    return {"status": "not_implemented", "entity_id": entity_id}


@router.post("/entity/{entity_id}/expand")
async def expand_entity(entity_id: str) -> dict[str, str]:
    """Load additional relationships for an entity."""
    return {"status": "not_implemented", "entity_id": entity_id}
