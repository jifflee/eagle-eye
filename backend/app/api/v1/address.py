"""Investigation lifecycle API endpoints."""

from __future__ import annotations

import logging
from uuid import UUID

from fastapi import APIRouter, HTTPException

from app.connectors.tier1.census_geocoder import CensusGeocoderConnector
from app.database import neo4j_driver, postgres_client
from app.enrichment.orchestrator import start_enrichment
from app.models.entities import Address, EntityType
from app.models.schemas import (
    AddressInput,
    EntityResponse,
    ExportResponse,
    GraphResponse,
    InvestigationCreatedResponse,
    InvestigationMetadata,
    InvestigationRequest,
    InvestigationResponse,
    InvestigationSummary,
    RelationshipResponse,
    SaveInvestigationRequest,
    SourceInfo,
)

logger = logging.getLogger(__name__)
router = APIRouter()

_geocoder = CensusGeocoderConnector()


@router.post("/address/validate")
async def validate_address(address: AddressInput) -> dict:
    """Validate an address via Census Geocoder.

    Returns the matched/standardized address for user confirmation,
    or an error with suggestions if no match is found.
    """
    from app.validation.address_validator import validate_address as client_validate

    # Step 1: Client-side format validation
    errors = client_validate(address.street, address.city, address.state, address.zip)
    if errors:
        return {"valid": False, "errors": errors, "matched": None, "suggestions": []}

    # Step 2: Census Geocoder — server-side verification
    entity = {
        "id": "validation",
        "street": address.street,
        "city": address.city,
        "state": address.state,
        "zip": address.zip,
    }

    from app.utils.http_client import fetch_json

    params = {
        "street": address.street,
        "city": address.city,
        "state": address.state,
        "zip": address.zip,
        "benchmark": "Public_AR_Current",
        "vintage": "Current_Current",
        "format": "json",
    }

    try:
        data = await fetch_json(
            "https://geocoding.geo.census.gov/geocoder/geographies/address",
            params=params,
        )
    except Exception as e:
        logger.warning("Census Geocoder unavailable: %s", e)
        return {
            "valid": True,
            "errors": [],
            "matched": {
                "street": address.street,
                "city": address.city,
                "state": address.state,
                "zip": address.zip,
                "formatted": f"{address.street}, {address.city}, {address.state} {address.zip}",
            },
            "suggestions": [],
            "warning": "Could not verify address — geocoder unavailable. Proceeding with entered address.",
        }

    matches = data.get("result", {}).get("addressMatches", [])

    if not matches:
        # Try a looser search (one-line query) for suggestions
        suggestions = []
        try:
            fallback = await fetch_json(
                "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress",
                params={
                    "address": f"{address.street}, {address.city}, {address.state} {address.zip}",
                    "benchmark": "Public_AR_Current",
                    "format": "json",
                },
            )
            for m in fallback.get("result", {}).get("addressMatches", []):
                coords = m.get("coordinates", {})
                suggestions.append({
                    "formatted": m.get("matchedAddress", ""),
                    "latitude": coords.get("y"),
                    "longitude": coords.get("x"),
                })
        except Exception:
            pass

        return {
            "valid": False,
            "errors": ["Address not found. Please check and try again."],
            "matched": None,
            "suggestions": suggestions,
        }

    # Return the best match for confirmation
    best = matches[0]
    coords = best.get("coordinates", {})
    geographies = best.get("geographies", {})
    tracts = geographies.get("Census Tracts", [])
    tract = tracts[0] if tracts else {}

    return {
        "valid": True,
        "errors": [],
        "matched": {
            "formatted": best.get("matchedAddress", ""),
            "latitude": coords.get("y"),
            "longitude": coords.get("x"),
            "tract": tract.get("TRACT", ""),
            "county": tract.get("COUNTY", ""),
            "state_fips": tract.get("STATE", ""),
            "geoid": tract.get("GEOID", ""),
        },
        "suggestions": [
            {
                "formatted": m.get("matchedAddress", ""),
                "latitude": m.get("coordinates", {}).get("y"),
                "longitude": m.get("coordinates", {}).get("x"),
            }
            for m in matches[1:4]  # Up to 3 alternatives
        ],
    }


@router.post("/investigation", response_model=InvestigationCreatedResponse)
async def create_investigation(request: InvestigationRequest) -> InvestigationCreatedResponse:
    """Submit address to start a new investigation."""
    addr = request.address

    # Create address entity in Neo4j
    address_entity = Address(
        street=addr.street,
        city=addr.city,
        state=addr.state,
        zip=addr.zip,
    )
    entity_props = {
        "id": str(address_entity.id),
        "street": addr.street,
        "city": addr.city,
        "state": addr.state,
        "zip": addr.zip,
        "address_type": "unknown",
    }

    try:
        await neo4j_driver.create_entity(EntityType.ADDRESS, entity_props)
    except Exception:
        logger.warning("Neo4j unavailable, continuing without graph write")

    # Create investigation record in PostgreSQL
    try:
        inv = await postgres_client.create_investigation(
            address_street=addr.street,
            address_city=addr.city,
            address_state=addr.state,
            address_zip=addr.zip,
            root_entity_id=str(address_entity.id),
        )
        investigation_id = inv["id"]
        address_str = inv["address"]
    except Exception:
        logger.warning("PostgreSQL unavailable, using in-memory fallback")
        from uuid import uuid4

        investigation_id = uuid4()
        address_str = f"{addr.street}, {addr.city}, {addr.state} {addr.zip}"

    # Trigger enrichment pipeline in background
    tier1_only = False
    if request.enrichment_config:
        tier1_only = request.enrichment_config.tier1_only

    await start_enrichment(
        investigation_id=investigation_id,
        address={
            "street": addr.street,
            "city": addr.city,
            "state": addr.state,
            "zip": addr.zip,
        },
        root_entity_id=str(address_entity.id),
        tier1_only=tier1_only,
    )

    return InvestigationCreatedResponse(
        id=investigation_id,
        status="initializing",
        address=address_str,
    )


@router.get("/investigation/{investigation_id}", response_model=InvestigationResponse)
async def get_investigation(investigation_id: UUID) -> InvestigationResponse:
    """Get full entity graph for an investigation."""
    # Get investigation metadata from PostgreSQL
    try:
        inv = await postgres_client.get_investigation(investigation_id)
    except Exception:
        inv = None

    if not inv:
        # Return empty graph for demo/offline mode
        address_str = "Unknown"
        status = "initializing"
        root_entity_id = None
        created_at = updated_at = __import__("datetime").datetime.utcnow()
    else:
        address_str = (
            f"{inv['address_street']}, {inv['address_city']}, "
            f"{inv['address_state']} {inv['address_zip']}"
        )
        status = inv["status"]
        root_entity_id = inv.get("root_entity_id")
        created_at = inv["created_at"]
        updated_at = inv["updated_at"]

    # Get graph data from Neo4j
    entities: list[EntityResponse] = []
    relationships: list[RelationshipResponse] = []

    if root_entity_id:
        try:
            graph = await neo4j_driver.get_investigation_graph(root_entity_id)
            logger.info(
                "Graph API: root=%s, raw entities=%d, raw rels=%d",
                root_entity_id[:8],
                len(graph.get("entities", [])),
                len(graph.get("relationships", [])),
            )
            for e in graph.get("entities", []):
                props = e.get("properties", {})
                labels = e.get("labels", [])
                entity_type = _labels_to_entity_type(labels)
                entities.append(
                    EntityResponse(
                        id=props.get("id", ""),
                        type=entity_type,
                        label=_entity_label(entity_type, props),
                        attributes=props,
                    )
                )
            for r in graph.get("relationships", []):
                relationships.append(
                    RelationshipResponse(
                        id=r.get("id", 0),
                        source_id=r.get("source_id", ""),
                        target_id=r.get("target_id", ""),
                        type=r.get("type", "UNKNOWN"),
                        properties=r.get("properties", {}),
                    )
                )
        except Exception:
            logger.warning("Neo4j unavailable, returning empty graph")

    return InvestigationResponse(
        id=investigation_id,
        address=address_str,
        status=status,
        graph=GraphResponse(entities=entities, relationships=relationships),
        metadata=InvestigationMetadata(
            total_entities=len(entities),
            total_relationships=len(relationships),
            enrichment_status=status,
            created_at=created_at,
            updated_at=updated_at,
        ),
    )


@router.get("/entity/{entity_id}", response_model=EntityResponse)
async def get_entity(entity_id: str) -> EntityResponse:
    """Get single entity with all relationships and provenance."""
    try:
        entity = await neo4j_driver.get_entity(entity_id)
    except Exception:
        entity = None

    if not entity:
        raise HTTPException(status_code=404, detail="Entity not found")

    labels = entity.pop("_labels", [])
    entity_type = _labels_to_entity_type(labels)

    # Get provenance from PostgreSQL
    sources: list[SourceInfo] = []
    try:
        provenance = await postgres_client.get_entity_provenance(entity_id)
        sources = [
            SourceInfo(
                connector_name=p["connector_name"],
                confidence=p["confidence_score"],
                retrieved_at=p["retrieval_date"],
            )
            for p in provenance
        ]
    except Exception:
        logger.warning("PostgreSQL unavailable, no provenance data")

    return EntityResponse(
        id=entity.get("id", entity_id),
        type=entity_type,
        label=_entity_label(entity_type, entity),
        attributes=entity,
        sources=sources,
    )


@router.post("/entity/{entity_id}/expand")
async def expand_entity(entity_id: str, depth: int = 1) -> GraphResponse:
    """Load additional relationships for an entity (N+1 hop)."""
    try:
        neighborhood = await neo4j_driver.get_entity_neighborhood(entity_id, depth)
    except Exception:
        return GraphResponse(entities=[], relationships=[])

    entities: list[EntityResponse] = []
    for n in neighborhood.get("neighbors", []):
        props = n.get("properties", {})
        labels = n.get("labels", [])
        entity_type = _labels_to_entity_type(labels)
        entities.append(
            EntityResponse(
                id=props.get("id", ""),
                type=entity_type,
                label=_entity_label(entity_type, props),
                attributes=props,
            )
        )

    relationships = [
        RelationshipResponse(
            id=0,
            source_id=r.get("source_id", ""),
            target_id=r.get("target_id", ""),
            type=r.get("type", "UNKNOWN"),
            properties=r.get("properties", {}),
        )
        for r in neighborhood.get("relationships", [])
    ]

    return GraphResponse(entities=entities, relationships=relationships)


@router.post("/investigation/{investigation_id}/save")
async def save_investigation(
    investigation_id: UUID,
    request: SaveInvestigationRequest,
) -> dict[str, str]:
    """Save an investigation with a name and notes."""
    try:
        await postgres_client.update_investigation(
            investigation_id,
            name=request.name,
            notes=request.notes,
        )
        await postgres_client.log_action(
            action="save_investigation",
            investigation_id=investigation_id,
            details={"name": request.name},
        )
    except Exception:
        logger.warning("PostgreSQL unavailable")

    return {"status": "saved", "investigation_id": str(investigation_id)}


@router.get("/investigation/{investigation_id}/audit")
async def get_audit_log(investigation_id: UUID) -> list[dict]:
    """Get audit log for an investigation."""
    try:
        entries = await postgres_client.get_audit_log(investigation_id)
        return entries
    except Exception:
        return []


@router.get("/saved-investigations", response_model=list[InvestigationSummary])
async def list_saved_investigations(
    limit: int = 50,
    offset: int = 0,
) -> list[InvestigationSummary]:
    """List all saved investigations."""
    try:
        rows = await postgres_client.list_investigations(limit, offset)
        return [
            InvestigationSummary(
                id=row["id"],
                name=row.get("name"),
                address=(
                    f"{row['address_street']}, {row['address_city']}, "
                    f"{row['address_state']} {row['address_zip']}"
                ),
                status=row["status"],
                entity_count=row.get("entity_count", 0),
                created_at=row["created_at"],
                updated_at=row["updated_at"],
            )
            for row in rows
        ]
    except Exception:
        logger.warning("PostgreSQL unavailable")
        return []


@router.delete("/investigation/{investigation_id}")
async def delete_investigation(investigation_id: UUID) -> dict[str, str]:
    """Delete an investigation."""
    try:
        deleted = await postgres_client.delete_investigation(investigation_id)
        if not deleted:
            raise HTTPException(status_code=404, detail="Investigation not found")
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=500, detail="Failed to delete investigation")

    return {"status": "deleted"}


@router.get("/investigation/{investigation_id}/export", response_model=ExportResponse)
async def export_investigation(
    investigation_id: UUID,
    format: str = "json",
) -> ExportResponse:
    """Export investigation as JSON or CSV."""
    inv_response = await get_investigation(investigation_id)

    if format == "csv":
        # Flatten entities into CSV-friendly rows
        import csv
        import io

        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(["id", "type", "label", "attributes"])
        for e in inv_response.graph.entities:
            attrs = "; ".join(f"{k}={v}" for k, v in (e.attributes or {}).items()
                             if k not in ("id", "type", "entity_type", "created_at", "updated_at"))
            writer.writerow([str(e.id), e.type.value, e.label, attrs])

        writer.writerow([])
        writer.writerow(["source_id", "target_id", "relationship_type"])
        for r in inv_response.graph.relationships:
            writer.writerow([str(r.source_id), str(r.target_id), r.type])

        return ExportResponse(format="csv", data={"csv": output.getvalue()})

    export_data = {
        "investigation_id": str(investigation_id),
        "address": inv_response.address,
        "entities": [e.model_dump(mode="json") for e in inv_response.graph.entities],
        "relationships": [
            r.model_dump(mode="json") for r in inv_response.graph.relationships
        ],
        "metadata": inv_response.metadata.model_dump(mode="json"),
    }

    return ExportResponse(format=format, data=export_data)


# === Helpers ===


def _labels_to_entity_type(labels: list[str]) -> EntityType:
    """Convert Neo4j labels to EntityType enum."""
    label_map = {
        "Person": EntityType.PERSON,
        "Address": EntityType.ADDRESS,
        "Property": EntityType.PROPERTY,
        "Business": EntityType.BUSINESS,
        "Case": EntityType.CASE,
        "Vehicle": EntityType.VEHICLE,
        "CrimeRecord": EntityType.CRIME_RECORD,
        "SocialProfile": EntityType.SOCIAL_PROFILE,
        "PhoneNumber": EntityType.PHONE_NUMBER,
        "EmailAddress": EntityType.EMAIL_ADDRESS,
        "EnvironmentalFacility": EntityType.ENVIRONMENTAL_FACILITY,
        "CensusTract": EntityType.CENSUS_TRACT,
    }
    for label in labels:
        if label in label_map:
            return label_map[label]
    return EntityType.ADDRESS


def _entity_label(entity_type: EntityType, props: dict) -> str:
    """Generate a human-readable label for an entity."""
    match entity_type:
        case EntityType.PERSON:
            return props.get("full_name") or f"{props.get('first_name', '')} {props.get('last_name', '')}"
        case EntityType.ADDRESS:
            return f"{props.get('street', '')}, {props.get('city', '')} {props.get('state', '')}"
        case EntityType.BUSINESS:
            return props.get("name", "Unknown Business")
        case EntityType.PROPERTY:
            return f"Parcel {props.get('apn', 'Unknown')}"
        case EntityType.CASE:
            return props.get("case_number", "Unknown Case")
        case EntityType.VEHICLE:
            return f"{props.get('year', '')} {props.get('make', '')} {props.get('model', '')}"
        case EntityType.CRIME_RECORD:
            return props.get("incident_type", "Crime")
        case EntityType.SOCIAL_PROFILE:
            return f"{props.get('platform', '')}/@{props.get('username', '')}"
        case EntityType.PHONE_NUMBER:
            return props.get("phone_number", "Unknown")
        case EntityType.EMAIL_ADDRESS:
            return props.get("email", "Unknown")
        case EntityType.ENVIRONMENTAL_FACILITY:
            return props.get("facility_name", "Unknown Facility")
        case EntityType.CENSUS_TRACT:
            return f"Tract {props.get('tract_number', '')}"
        case _:
            return str(props.get("id", "Unknown"))
