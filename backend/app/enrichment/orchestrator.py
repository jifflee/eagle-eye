"""Enrichment orchestrator — runs connectors against an investigation address.

Runs as a background asyncio task. Each connector runs in parallel within
its phase, results are written to Neo4j + PostgreSQL as they arrive.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any
from uuid import UUID, uuid4

from app.connectors.base import ConnectorResult
from app.connectors.registry import discover_connectors
from app.database import neo4j_driver, postgres_client
from app.models.entities import EntityType

logger = logging.getLogger(__name__)

# Track running enrichments so we can pause/cancel
_running_tasks: dict[str, asyncio.Task] = {}


async def start_enrichment(
    investigation_id: UUID,
    address: dict[str, str],
    root_entity_id: str,
    tier1_only: bool = False,
) -> None:
    """Start enrichment as a background task."""
    logger.info("Creating enrichment task for %s", investigation_id)
    task = asyncio.ensure_future(
        _run_enrichment(investigation_id, address, root_entity_id, tier1_only)
    )

    def _on_done(t: asyncio.Task) -> None:
        exc = t.exception() if not t.cancelled() else None
        if exc:
            logger.error("Enrichment task failed for %s: %s", investigation_id, exc)
        else:
            logger.info("Enrichment task finished for %s", investigation_id)

    task.add_done_callback(_on_done)
    _running_tasks[str(investigation_id)] = task


async def _run_enrichment(
    investigation_id: UUID,
    address: dict[str, str],
    root_entity_id: str,
    tier1_only: bool,
) -> None:
    """Run the full enrichment pipeline."""
    try:
        await _do_enrichment(investigation_id, address, root_entity_id, tier1_only)
    except Exception:
        logger.exception("Enrichment failed for investigation %s", investigation_id)
        try:
            await postgres_client.update_investigation(investigation_id, status="failed")
        except Exception:
            pass
    finally:
        _running_tasks.pop(str(investigation_id), None)


async def _do_enrichment(
    investigation_id: UUID,
    address: dict[str, str],
    root_entity_id: str,
    tier1_only: bool,
) -> None:
    """Inner enrichment logic."""
    logger.info("Starting enrichment for investigation %s", investigation_id)

    # Wait for Neo4j to be available (up to 60s)
    for attempt in range(12):
        if await neo4j_driver.check_health():
            break
        logger.info("Waiting for Neo4j... (attempt %d/12)", attempt + 1)
        await asyncio.sleep(5)

    connectors = discover_connectors()

    # Skip connectors that require API keys we don't have
    DISABLED_CONNECTORS = {"fbi_crime", "nhtsa_vpic"}
    connectors = {
        k: v for k, v in connectors.items()
        if k not in DISABLED_CONNECTORS
    }

    # Filter to tier 1 only if requested
    if tier1_only:
        connectors = {k: v for k, v in connectors.items() if v.tier == 1}

    # Register all connectors as pending
    for name in connectors:
        try:
            await postgres_client.upsert_connector_status(
                investigation_id, name, "pending"
            )
        except Exception:
            pass

    # Update investigation status
    try:
        await postgres_client.update_investigation(investigation_id, status="enriching")
    except Exception:
        pass

    # Build the address entity dict for connectors
    address_entity: dict[str, Any] = {
        "id": root_entity_id,
        "type": "ADDRESS",
        **address,
    }

    # === Phase 1: Geocoding ===
    geocoder = connectors.get("census_geocoder")
    if geocoder:
        result = await _run_connector(investigation_id, geocoder, address_entity)
        # Update address entity with geocoded coordinates
        if result and result.raw_data:
            updates = result.raw_data.get("address_updates", {})
            if updates:
                address_entity.update(updates)
                try:
                    await neo4j_driver.update_entity(root_entity_id, updates)
                except Exception:
                    pass

    # === Phase 2: Address enrichment (parallel) ===
    phase2_names = ["census_data", "epa_echo", "openfema", "nominatim"]
    phase2 = [connectors[n] for n in phase2_names if n in connectors]

    if phase2:
        await asyncio.gather(
            *[_run_connector(investigation_id, c, address_entity) for c in phase2],
            return_exceptions=True,
        )

    # === Phase 3: Entity discovery (SEC — search by address) ===
    # CourtListener only works with PERSON/BUSINESS entities, not ADDRESS
    # so we skip it in the address phase — it will run during person enrichment
    phase3_names = ["sec_edgar"]
    phase3 = [connectors[n] for n in phase3_names if n in connectors]

    if phase3:
        await asyncio.gather(
            *[_run_connector(investigation_id, c, address_entity) for c in phase3],
            return_exceptions=True,
        )

    # === Phase 4: Recursive discovery ===
    # Walk discovered entities (people, businesses) and enrich them further
    # e.g., PERSON → court cases, BUSINESS → officers
    from app.enrichment.discovery import run_discovery

    try:
        discovery_result = await run_discovery(
            investigation_id=investigation_id,
            root_entity=address_entity,
            max_depth=2,  # Keep shallow for now
            max_entities=200,
        )
        logger.info(
            "Discovery found %d entities, %d relationships",
            discovery_result["entities_discovered"],
            discovery_result["relationships_discovered"],
        )
    except Exception:
        logger.exception("Discovery phase failed")

    # === Phase 5: Deduplication ===
    from app.enrichment.deduplicator import run_deduplication

    try:
        # Fetch all entities from the graph
        graph = await neo4j_driver.get_investigation_graph(root_entity_id, max_depth=3)
        all_entities = [
            {**e.get("properties", {}), "type": _label_to_type(e.get("labels", []))}
            for e in graph.get("entities", [])
        ]

        duplicate_groups = await run_deduplication(str(investigation_id), all_entities)
        if duplicate_groups:
            logger.info("Found %d duplicate groups", len(duplicate_groups))
            # Log duplicates for now — auto-merge is a future enhancement
            for group in duplicate_groups:
                logger.info(
                    "Duplicate: primary=%s, dupes=%s, confidence=%.2f (%s)",
                    group.primary_id[:8],
                    [d[:8] for d in group.duplicate_ids],
                    group.confidence,
                    group.match_reason,
                )
    except Exception:
        logger.exception("Deduplication phase failed")

    # Mark investigation complete
    try:
        entity_count = await neo4j_driver.get_entity_count()
        rel_count = await neo4j_driver.get_relationship_count()
        await postgres_client.update_investigation(
            investigation_id,
            status="complete",
            entity_count=entity_count,
            relationship_count=rel_count,
        )
    except Exception:
        pass

    logger.info("Enrichment complete for investigation %s", investigation_id)


async def _run_connector(
    investigation_id: UUID,
    connector: Any,
    entity: dict[str, Any],
) -> ConnectorResult | None:
    """Run a single connector and persist results."""
    name = connector.name
    logger.info("Running connector: %s", name)

    # Mark as running
    try:
        await postgres_client.upsert_connector_status(
            investigation_id, name, "running"
        )
    except Exception as e:
        logger.error("Failed to update status to running for %s: %s", name, e)

    try:
        result = await connector.discover(entity)
    except Exception as e:
        logger.error("Connector %s failed: %s", name, e)
        try:
            await postgres_client.upsert_connector_status(
                investigation_id, name, "failed", error_message=str(e)
            )
        except Exception as e2:
            logger.error("Failed to update status to failed for %s: %s", name, e2)
        return None

    if result.error:
        logger.warning("Connector %s returned error: %s", name, result.error)
        try:
            await postgres_client.upsert_connector_status(
                investigation_id, name, "failed", error_message=result.error
            )
        except Exception as e:
            logger.error("Failed to update status to failed for %s: %s", name, e)
        return result

    # Persist discovered entities to Neo4j
    entities_found = 0
    for ent in result.entities:
        ent_type_str = ent.get("type", "ADDRESS")
        try:
            ent_type = EntityType(ent_type_str)
        except ValueError:
            ent_type = EntityType.ADDRESS

        ent_id = ent.get("id", str(uuid4()))
        ent["id"] = ent_id

        try:
            await neo4j_driver.merge_entity(ent_type, "id", ent_id, ent)
            entities_found += 1
        except Exception as e:
            logger.warning("Failed to write entity from %s: %s", name, e)

        # Record provenance
        try:
            await postgres_client.create_source_record(
                entity_id=ent_id,
                connector_name=name,
                confidence_score=result.confidence,
                investigation_id=investigation_id,
                raw_data=ent,
            )
        except Exception:
            pass

    # Persist relationships
    for rel in result.relationships:
        try:
            await neo4j_driver.create_relationship(
                source_id=str(rel["source_id"]),
                target_id=str(rel["target_id"]),
                rel_type=rel["type"],
                properties=rel.get("properties", {}),
            )
        except Exception as e:
            logger.warning("Failed to write relationship from %s: %s", name, e)

    # Mark connector complete
    try:
        await postgres_client.upsert_connector_status(
            investigation_id, name, "complete", entities_found=entities_found
        )
    except Exception as e:
        logger.error("Failed to update status to complete for %s: %s", name, e)

    logger.info("Connector %s complete: %d entities", name, entities_found)
    return result


def _label_to_type(labels: list[str]) -> str:
    """Convert Neo4j labels to entity type string."""
    label_map = {
        "Person": "PERSON", "Address": "ADDRESS", "Property": "PROPERTY",
        "Business": "BUSINESS", "Case": "CASE", "Vehicle": "VEHICLE",
        "CrimeRecord": "CRIME_RECORD", "SocialProfile": "SOCIAL_PROFILE",
        "PhoneNumber": "PHONE_NUMBER", "EmailAddress": "EMAIL_ADDRESS",
        "EnvironmentalFacility": "ENVIRONMENTAL_FACILITY",
        "CensusTract": "CENSUS_TRACT",
    }
    for label in labels:
        if label in label_map:
            return label_map[label]
    return "ADDRESS"
