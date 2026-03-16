"""Enrichment status and control API endpoints."""

from __future__ import annotations

import logging
from uuid import UUID

from fastapi import APIRouter

from app.database import postgres_client
from app.models.schemas import (
    ConnectorStatusResponse,
    EnrichmentControlRequest,
    EnrichmentStatusResponse,
    SourceListItem,
    SourceListResponse,
)

logger = logging.getLogger(__name__)
router = APIRouter()

# Registry of all available connectors
AVAILABLE_CONNECTORS: list[SourceListItem] = [
    SourceListItem(name="census_geocoder", tier=1, requires_auth=False, description="US Census Geocoder — address to coordinates + census tract", status="available"),
    SourceListItem(name="census_data", tier=1, requires_auth=False, description="Census Data API — demographics by tract", status="available"),
    SourceListItem(name="fbi_crime", tier=1, requires_auth=False, description="FBI Crime Data API — crime statistics by county", status="available"),
    SourceListItem(name="epa_echo", tier=1, requires_auth=False, description="EPA ECHO — environmental facilities and violations", status="available"),
    SourceListItem(name="sec_edgar", tier=1, requires_auth=False, description="SEC EDGAR — corporate filings and officers", status="available"),
    SourceListItem(name="courtlistener", tier=1, requires_auth=False, description="CourtListener — federal/state court records", status="available"),
    SourceListItem(name="openfema", tier=1, requires_auth=False, description="OpenFEMA — disaster declarations and flood data", status="available"),
    SourceListItem(name="nominatim", tier=1, requires_auth=False, description="OSM Nominatim — backup geocoder", status="available"),
    SourceListItem(name="nhtsa_vpic", tier=1, requires_auth=False, description="NHTSA vPIC — VIN decoding and recalls", status="available"),
    SourceListItem(name="gwinnett_parcel", tier=2, requires_auth=False, description="Gwinnett County ArcGIS — parcel data", status="available"),
    SourceListItem(name="ga_secretary_state", tier=2, requires_auth=False, description="GA Secretary of State — business registrations", status="available"),
    SourceListItem(name="gwinnett_courts", tier=2, requires_auth=False, description="Gwinnett Courts — county case search", status="available"),
    SourceListItem(name="qpublic", tier=2, requires_auth=False, description="qPublic — detailed property records", status="available"),
    SourceListItem(name="gsccca_deeds", tier=2, requires_auth=False, description="GSCCCA — deeds, liens, UCC filings", status="available"),
    SourceListItem(name="gbi_sex_offender", tier=2, requires_auth=False, description="GBI Sex Offender Registry", status="available"),
    SourceListItem(name="gwinnett_sheriff_jail", tier=2, requires_auth=False, description="Gwinnett Sheriff — inmate records", status="available"),
    SourceListItem(name="opencorporates", tier=3, requires_auth=False, description="OpenCorporates — global company registry", status="available"),
    SourceListItem(name="google_places", tier=3, requires_auth=True, description="Google Places — nearby POIs", status="unavailable"),
    SourceListItem(name="hunter_io", tier=3, requires_auth=True, description="Hunter.io — email lookup", status="unavailable"),
    SourceListItem(name="numverify", tier=3, requires_auth=True, description="NumVerify — phone validation", status="unavailable"),
]


@router.get("/enrichment/status/{investigation_id}", response_model=EnrichmentStatusResponse)
async def enrichment_status(investigation_id: UUID) -> EnrichmentStatusResponse:
    """Get real-time enrichment pipeline status."""
    completed = []
    in_progress = []
    pending = []
    failed = []
    connectors: list[ConnectorStatusResponse] = []
    total_entities = 0

    try:
        statuses = await postgres_client.get_connector_statuses(investigation_id)
        for s in statuses:
            name = s["connector_name"]
            status = s["status"]
            total_entities += s.get("entities_found", 0)

            connectors.append(
                ConnectorStatusResponse(
                    connector_name=name,
                    tier=_get_connector_tier(name),
                    status=status,
                    entities_found=s.get("entities_found", 0),
                    error_message=s.get("error_message"),
                    started_at=s.get("started_at"),
                    completed_at=s.get("completed_at"),
                )
            )

            match status:
                case "complete":
                    completed.append(name)
                case "running":
                    in_progress.append(name)
                case "pending":
                    pending.append(name)
                case "failed" | "rate_limited":
                    failed.append(name)
    except Exception:
        logger.warning("PostgreSQL unavailable")

    # Determine overall status
    if in_progress:
        overall_status = "enriching"
    elif pending:
        overall_status = "initializing"
    elif failed and not completed:
        overall_status = "failed"
    else:
        overall_status = "complete"

    return EnrichmentStatusResponse(
        investigation_id=investigation_id,
        status=overall_status,
        completed_sources=completed,
        in_progress_sources=in_progress,
        pending_sources=pending,
        failed_sources=failed,
        discovered_entities=total_entities,
        connectors=connectors,
    )


@router.post("/enrichment/{investigation_id}/control")
async def enrichment_control(
    investigation_id: UUID,
    request: EnrichmentControlRequest,
) -> dict[str, str]:
    """Pause, resume, or cancel enrichment."""
    # TODO: Integrate with Celery task management (Issue #23 / 4.1)
    try:
        await postgres_client.log_action(
            action=f"enrichment_{request.action}",
            investigation_id=investigation_id,
        )
    except Exception:
        pass

    return {"status": request.action, "investigation_id": str(investigation_id)}


@router.get("/sources", response_model=SourceListResponse)
async def list_sources() -> SourceListResponse:
    """List all available data source connectors."""
    return SourceListResponse(sources=AVAILABLE_CONNECTORS)


@router.post("/investigation/{investigation_id}/source/{source}/retry")
async def retry_source(investigation_id: UUID, source: str) -> dict[str, str]:
    """Retry a failed data source."""
    try:
        await postgres_client.upsert_connector_status(
            investigation_id=investigation_id,
            connector_name=source,
            status="pending",
        )
        await postgres_client.log_action(
            action="retry_source",
            investigation_id=investigation_id,
            details={"source": source},
        )
    except Exception:
        logger.warning("PostgreSQL unavailable")

    # TODO: Re-trigger the connector via Celery (Issue #23 / 4.1)

    return {"status": "retrying", "source": source}


def _get_connector_tier(connector_name: str) -> int:
    """Get the tier for a connector by name."""
    for c in AVAILABLE_CONNECTORS:
        if c.name == connector_name:
            return c.tier
    return 0
