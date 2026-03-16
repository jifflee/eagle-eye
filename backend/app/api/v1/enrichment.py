from fastapi import APIRouter

router = APIRouter()


@router.get("/enrichment/status/{investigation_id}")
async def enrichment_status(investigation_id: str) -> dict[str, str]:
    """Get real-time enrichment pipeline status."""
    return {"status": "not_implemented", "investigation_id": investigation_id}


@router.post("/enrichment/{investigation_id}/control")
async def enrichment_control(investigation_id: str) -> dict[str, str]:
    """Pause, resume, or cancel enrichment."""
    return {"status": "not_implemented"}


@router.get("/sources")
async def list_sources() -> dict[str, list[str]]:
    """List all available data source connectors."""
    return {"sources": []}


@router.post("/investigation/{investigation_id}/source/{source}/retry")
async def retry_source(investigation_id: str, source: str) -> dict[str, str]:
    """Retry a failed data source."""
    return {"status": "not_implemented"}
