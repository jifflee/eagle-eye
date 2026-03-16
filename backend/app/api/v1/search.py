from fastapi import APIRouter

router = APIRouter()


@router.post("/search")
async def search_entities() -> dict[str, list[str]]:
    """Full-text search across all entities."""
    return {"results": []}
