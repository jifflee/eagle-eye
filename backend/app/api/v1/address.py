from fastapi import APIRouter

router = APIRouter()


@router.post("/investigation")
async def create_investigation() -> dict[str, str]:
    """Submit address to start a new investigation."""
    return {"status": "not_implemented"}


@router.get("/investigation/{investigation_id}")
async def get_investigation(investigation_id: str) -> dict[str, str]:
    """Get full entity graph for an investigation."""
    return {"status": "not_implemented", "investigation_id": investigation_id}


@router.post("/investigation/{investigation_id}/save")
async def save_investigation(investigation_id: str) -> dict[str, str]:
    """Save an investigation."""
    return {"status": "not_implemented"}


@router.get("/saved-investigations")
async def list_saved_investigations() -> dict[str, list[str]]:
    """List all saved investigations."""
    return {"investigations": []}


@router.get("/investigation/{investigation_id}/export")
async def export_investigation(investigation_id: str) -> dict[str, str]:
    """Export investigation as JSON or CSV."""
    return {"status": "not_implemented"}
