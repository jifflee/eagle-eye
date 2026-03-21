"""Entity discovery algorithm — recursive, depth-limited entity expansion.

Starting from a root entity (typically an ADDRESS), discovers related entities
by running applicable connectors, then recursively enriches each discovered
entity up to a configurable depth.

Discovery rules:
  ADDRESS  → PERSONs (property owners), BUSINESSes (SOS, SEC)
  PERSON   → CASEs (courts), BUSINESSes (officer roles), relatives
  BUSINESS → PERSONs (officers), CASEs (lawsuits), related BUSINESSes
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any
from uuid import UUID

from app.connectors.base import BaseConnector, ConnectorResult
from app.connectors.registry import discover_connectors
from app.database import neo4j_driver, postgres_client
from app.models.entities import EntityType

logger = logging.getLogger(__name__)

# Maximum entities per investigation to prevent runaway discovery
DEFAULT_MAX_ENTITIES = 500
DEFAULT_MAX_DEPTH = 3


async def run_discovery(
    investigation_id: UUID,
    root_entity: dict[str, Any],
    max_depth: int = DEFAULT_MAX_DEPTH,
    max_entities: int = DEFAULT_MAX_ENTITIES,
) -> dict[str, Any]:
    """Run recursive entity discovery starting from root_entity.

    Args:
        investigation_id: The investigation this discovery belongs to.
        root_entity: Dict with id, type, and entity attributes.
        max_depth: Maximum hops from root entity.
        max_entities: Stop discovery after this many entities.

    Returns:
        Summary dict with counts of discovered entities and relationships.
    """
    visited: set[str] = set()
    total_entities = 0
    total_relationships = 0

    async def _discover_recursive(
        entity: dict[str, Any],
        depth: int,
    ) -> None:
        nonlocal total_entities, total_relationships

        entity_id = str(entity.get("id", ""))
        if not entity_id or entity_id in visited:
            return
        if depth > max_depth:
            return
        if total_entities >= max_entities:
            logger.info(
                "Max entities reached (%d), stopping discovery", max_entities
            )
            return

        visited.add(entity_id)

        entity_type_str = entity.get("type", "")
        try:
            entity_type = EntityType(entity_type_str)
        except ValueError:
            return

        # Find connectors that can discover from this entity type
        # Exclude disabled scrapers (sites that prohibit automated access)
        DISABLED = {
            "qpublic", "gsccca_deeds", "gbi_sex_offender",
            "gwinnett_sheriff_jail", "gwinnett_courts", "ga_secretary_state",
        }
        connectors = discover_connectors()
        applicable = [
            c for c in connectors.values()
            if c.can_discover_from(entity_type) and c.name not in DISABLED
        ]

        if not applicable:
            return

        logger.info(
            "Discovery depth=%d: %s [%s] — %d applicable connectors",
            depth, entity_id[:8], entity_type_str, len(applicable),
        )

        # Run applicable connectors in parallel
        results = await asyncio.gather(
            *[_safe_discover(c, entity) for c in applicable],
            return_exceptions=True,
        )

        # Process results — persist new entities and recurse
        new_entities: list[dict[str, Any]] = []

        for result in results:
            if isinstance(result, Exception):
                logger.warning("Discovery connector error: %s", result)
                continue
            if result is None or result.error:
                continue

            for ent in result.entities:
                ent_id = str(ent.get("id", ""))
                if ent_id in visited:
                    continue

                # Persist to Neo4j
                ent_type_str = ent.get("type", "ADDRESS")
                try:
                    ent_type = EntityType(ent_type_str)
                except ValueError:
                    continue

                try:
                    await neo4j_driver.merge_entity(ent_type, "id", ent_id, ent)
                    total_entities += 1
                except Exception as e:
                    logger.warning("Failed to persist discovered entity: %s", e)
                    continue

                # Record provenance
                try:
                    await postgres_client.create_source_record(
                        entity_id=ent_id,
                        connector_name=result.source_name,
                        confidence_score=result.confidence,
                        investigation_id=investigation_id,
                    )
                except Exception:
                    pass

                new_entities.append(ent)

            # Persist relationships
            for rel in result.relationships:
                try:
                    await neo4j_driver.create_relationship(
                        source_id=str(rel["source_id"]),
                        target_id=str(rel["target_id"]),
                        rel_type=rel["type"],
                        properties=rel.get("properties", {}),
                    )
                    total_relationships += 1
                except Exception as e:
                    logger.warning("Failed to persist relationship: %s", e)

        # Recurse into newly discovered entities (one level deeper)
        for ent in new_entities:
            if total_entities >= max_entities:
                break
            await _discover_recursive(ent, depth + 1)

    # Start discovery from root
    await _discover_recursive(root_entity, depth=0)

    logger.info(
        "Discovery complete: %d entities, %d relationships (depth=%d)",
        total_entities, total_relationships, max_depth,
    )

    return {
        "entities_discovered": total_entities,
        "relationships_discovered": total_relationships,
        "entities_visited": len(visited),
    }


async def _safe_discover(
    connector: BaseConnector,
    entity: dict[str, Any],
) -> ConnectorResult | None:
    """Run a connector's discover method with error handling."""
    try:
        return await connector.discover(entity)
    except Exception as e:
        logger.warning("Connector %s discover failed: %s", connector.name, e)
        return None
