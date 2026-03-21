"""Enrichment orchestrator — runs connectors against an investigation address.

Supports two execution modes:
- Celery: distributed task queue with pause/resume/cancel (when Redis is available)
- asyncio: in-process background task (fallback when Celery is unavailable)
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any
from uuid import UUID, uuid4

from app.connectors.base import ConnectorResult
from app.connectors.registry import discover_connectors
from app.database import neo4j_driver, postgres_client
from app.enrichment import log_store
from app.models.entities import EntityType

logger = logging.getLogger(__name__)

# Track running enrichments for asyncio fallback mode
_running_tasks: dict[str, asyncio.Task] = {}


async def start_enrichment(
    investigation_id: UUID,
    address: dict[str, str],
    root_entity_id: str,
    tier1_only: bool = False,
) -> str | None:
    """Start enrichment — uses Celery if available, falls back to asyncio.

    Returns the Celery task ID if dispatched via Celery, or None for asyncio.
    """
    # Try Celery first
    try:
        from app.enrichment.tasks import run_enrichment_task

        result = run_enrichment_task.delay(
            str(investigation_id), address, root_entity_id, tier1_only
        )
        logger.info("Enrichment dispatched via Celery: task=%s inv=%s", result.id, investigation_id)
        return result.id
    except Exception:
        logger.info("Celery unavailable, using asyncio fallback for %s", investigation_id)

    # Asyncio fallback
    task = asyncio.ensure_future(
        _run_enrichment_async(investigation_id, address, root_entity_id, tier1_only)
    )

    def _on_done(t: asyncio.Task) -> None:
        exc = t.exception() if not t.cancelled() else None
        if exc:
            logger.error("Enrichment task failed for %s: %s", investigation_id, exc)
        else:
            logger.info("Enrichment task finished for %s", investigation_id)

    task.add_done_callback(_on_done)
    _running_tasks[str(investigation_id)] = task
    return None


async def cancel_enrichment(investigation_id: UUID) -> bool:
    """Cancel a running enrichment task."""
    inv_id = str(investigation_id)

    # Try Celery first
    try:
        from app.enrichment.tasks import get_task_id
        from app.celery_app import celery_app

        task_id = get_task_id(inv_id)
        if task_id:
            celery_app.control.revoke(task_id, terminate=True)
            logger.info("Celery task %s revoked for %s", task_id, inv_id)
            await postgres_client.update_investigation(investigation_id, status="cancelled")
            return True
    except Exception:
        pass

    # Asyncio fallback
    task = _running_tasks.get(inv_id)
    if task and not task.done():
        task.cancel()
        _running_tasks.pop(inv_id, None)
        try:
            await postgres_client.update_investigation(investigation_id, status="cancelled")
        except Exception:
            pass
        logger.info("Asyncio task cancelled for %s", inv_id)
        return True

    return False


async def _run_enrichment_async(
    investigation_id: UUID,
    address: dict[str, str],
    root_entity_id: str,
    tier1_only: bool,
) -> None:
    """Asyncio wrapper for the enrichment pipeline."""
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

    # Disabled connectors now live in connectors/_disabled/ and are not
    # auto-discovered by the registry. See docs/DATA_SOURCE_CLASSIFICATION.md.

    # Filter to tier 1 only if requested
    if tier1_only:
        connectors = {k: v for k, v in connectors.items() if v.tier == 1}

    # Register connectors — only "pending" for address-applicable ones,
    # "skipped" for connectors that need PERSON/BUSINESS (they'll run in discovery)
    from app.models.entities import EntityType as ET

    address_connectors = set()
    for name, conn in connectors.items():
        is_address_applicable = conn.can_discover_from(ET.ADDRESS)
        status = "pending" if is_address_applicable else "skipped"
        address_connectors.add(name) if is_address_applicable else None
        try:
            await postgres_client.upsert_connector_status(
                investigation_id, name, status,
                error_message=None if is_address_applicable else "Awaiting person/business discovery",
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

    # Ensure root address entity exists in Neo4j (may have failed during API call)
    try:
        await neo4j_driver.merge_entity(
            EntityType.ADDRESS, "id", root_entity_id, address_entity
        )
        logger.info("Root address entity ensured in Neo4j: %s", root_entity_id)
    except Exception as e:
        logger.error("Failed to create root address entity: %s", e)

    # === Phase 1: Geocoding ===
    geocoder = connectors.get("census_geocoder")
    if geocoder:
        result = await _run_connector(investigation_id, geocoder, address_entity)
        # Update address entity with geocoded coordinates AND tract info
        if result and result.raw_data:
            updates = result.raw_data.get("address_updates", {})
            if updates:
                address_entity.update(updates)

            # Extract tract FIPS for census_data connector
            tract_info = result.raw_data.get("tract_info", {})
            if tract_info:
                address_entity["state_fips"] = tract_info.get("STATE", "")
                address_entity["county_fips"] = tract_info.get("COUNTY", "")
                address_entity["tract_number"] = tract_info.get("TRACT", "")
                address_entity["geoid"] = tract_info.get("GEOID", "")

            try:
                await neo4j_driver.update_entity(root_entity_id, {
                    k: v for k, v in address_entity.items()
                    if k in ("latitude", "longitude", "state_fips", "county_fips", "tract_number", "geoid")
                    and v
                })
            except Exception:
                pass

    # === Phase 2: Address enrichment — Tier 1 APIs (parallel) ===
    phase2_names = [
        "census_data", "fbi_crime", "epa_echo", "openfema", "nominatim",
        "openfec", "fdic_bankfind", "overpass_osm", "propublica_nonprofit",
    ]
    phase2 = [connectors[n] for n in phase2_names if n in connectors]

    if phase2:
        await asyncio.gather(
            *[_run_connector(investigation_id, c, address_entity) for c in phase2],
            return_exceptions=True,
        )

    # === Phase 2b: Address enrichment — Tier 2 county sources (API only) ===
    phase2b_names = ["gwinnett_parcel"]  # ArcGIS REST API — no scraping
    phase2b = [connectors[n] for n in phase2b_names if n in connectors]

    if phase2b:
        await asyncio.gather(
            *[_run_connector(investigation_id, c, address_entity) for c in phase2b],
            return_exceptions=True,
        )

    # === Phase 3: Address-level entity discovery ===
    # Only connectors that accept ADDRESS type. Person/business connectors
    # (usaspending, uspto, fcc, wayback) run in Phase 4 discovery per-entity.
    phase3_names = ["sec_edgar"]
    phase3 = [connectors[n] for n in phase3_names if n in connectors]

    if phase3:
        await asyncio.gather(
            *[_run_connector(investigation_id, c, address_entity) for c in phase3],
            return_exceptions=True,
        )

    # === Phase 4: Recursive discovery ===
    # Fetch all entities already in the graph (from phases 1-3) and run
    # discovery on each. This ensures PERSON entities from parcel records
    # get enriched through courts, SOS, and OpenCorporates.
    from app.enrichment.discovery import run_discovery

    # Build entity list from Neo4j graph
    discovery_entities = [address_entity]
    try:
        graph = await neo4j_driver.get_investigation_graph(root_entity_id, max_depth=2)
        for e in graph.get("entities", []):
            props = e.get("properties", {})
            labels = e.get("labels", [])
            etype = _label_to_type(labels)
            if etype in ("PERSON", "BUSINESS") and props.get("id") != root_entity_id:
                discovery_entities.append({"type": etype, **props})
    except Exception:
        logger.warning("Could not fetch graph for discovery seeding")

    logger.info("Discovery phase: %d seed entities", len(discovery_entities))

    try:
        discovery_result = await run_discovery(
            investigation_id=investigation_id,
            root_entity=address_entity,
            max_depth=2,
            max_entities=200,
        )
        # Also run discovery from each discovered person/business
        for seed in discovery_entities[1:]:  # Skip root address (already done)
            if discovery_result["entities_discovered"] >= 200:
                break
            sub_result = await run_discovery(
                investigation_id=investigation_id,
                root_entity=seed,
                max_depth=1,  # Shallow for chained entities
                max_entities=200 - discovery_result["entities_discovered"],
            )
            discovery_result["entities_discovered"] += sub_result["entities_discovered"]
            discovery_result["relationships_discovered"] += sub_result["relationships_discovered"]
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
    import time as _time

    name = connector.name
    inv_id = str(investigation_id)
    start = _time.time()

    logger.info("Running connector: %s", name)
    log_store.log(inv_id, "info", name, f"Starting {name}...")

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
        elapsed = int((_time.time() - start) * 1000)
        logger.error("Connector %s failed: %s", name, e)
        log_store.log(inv_id, "error", name, f"Exception: {e}", duration_ms=elapsed)
        try:
            await postgres_client.upsert_connector_status(
                investigation_id, name, "failed", error_message=str(e)
            )
        except Exception as e2:
            logger.error("Failed to update status to failed for %s: %s", name, e2)
        return None

    elapsed = int((_time.time() - start) * 1000)

    if result.error:
        logger.warning("Connector %s returned error: %s", name, result.error)
        log_store.log(inv_id, "warn", name, result.error, duration_ms=elapsed)
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
    log_store.log(
        inv_id, "info", name,
        f"Complete: {entities_found} entities found",
        entities_found=entities_found,
        duration_ms=elapsed,
    )
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
