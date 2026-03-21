"""Neo4j database driver — async connection pool and graph operations."""

from __future__ import annotations

import logging
from typing import Any
from uuid import UUID

from neo4j import AsyncGraphDatabase, AsyncDriver, AsyncSession

from app.config import settings
from app.models.entities import EntityType

logger = logging.getLogger(__name__)

_driver: AsyncDriver | None = None


async def get_driver() -> AsyncDriver:
    global _driver
    if _driver is None:
        _driver = AsyncGraphDatabase.driver(
            settings.neo4j_uri,
            auth=(settings.neo4j_user, settings.neo4j_password),
        )
    return _driver


async def close_driver() -> None:
    global _driver
    if _driver is not None:
        await _driver.close()
        _driver = None


async def check_health() -> bool:
    try:
        driver = await get_driver()
        await driver.verify_connectivity()
        return True
    except Exception:
        logger.exception("Neo4j health check failed")
        return False


# === Entity Operations ===


async def create_entity(
    entity_type: EntityType,
    properties: dict[str, Any],
) -> dict[str, Any]:
    """Create a node in Neo4j."""
    label = entity_type.value.replace("_", "")  # CRIME_RECORD -> CrimeRecord
    # Convert label to PascalCase
    label = "".join(word.capitalize() for word in entity_type.value.split("_"))

    props = _serialize_props(properties)
    query = f"CREATE (n:{label} $props) RETURN n"

    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(query, props=props)
        record = await result.single()
        return dict(record["n"]) if record else {}


async def get_entity(entity_id: str) -> dict[str, Any] | None:
    """Get a single entity by ID."""
    query = "MATCH (n {id: $id}) RETURN n, labels(n) AS labels"
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(query, id=entity_id)
        record = await result.single()
        if record:
            data = dict(record["n"])
            data["_labels"] = record["labels"]
            return data
        return None


async def update_entity(
    entity_id: str,
    properties: dict[str, Any],
) -> dict[str, Any] | None:
    """Update entity properties by ID."""
    props = _serialize_props(properties)
    query = "MATCH (n {id: $id}) SET n += $props RETURN n"
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(query, id=entity_id, props=props)
        record = await result.single()
        return dict(record["n"]) if record else None


async def merge_entity(
    entity_type: EntityType,
    merge_key: str,
    merge_value: str,
    properties: dict[str, Any],
) -> dict[str, Any]:
    """Merge (upsert) an entity by a unique key."""
    label = "".join(word.capitalize() for word in entity_type.value.split("_"))
    props = _serialize_props(properties)
    query = (
        f"MERGE (n:{label} {{{merge_key}: $merge_value}}) "
        f"ON CREATE SET n += $props "
        f"ON MATCH SET n += $props "
        f"RETURN n"
    )
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(query, merge_value=merge_value, props=props)
        record = await result.single()
        return dict(record["n"]) if record else {}


# === Relationship Operations ===


async def create_relationship(
    source_id: str,
    target_id: str,
    rel_type: str,
    properties: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Create a relationship between two entities."""
    props = _serialize_props(properties or {})
    query = (
        "MATCH (a {id: $source_id}), (b {id: $target_id}) "
        f"CREATE (a)-[r:{rel_type} $props]->(b) "
        "RETURN type(r) AS type, properties(r) AS props"
    )
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(
            query, source_id=source_id, target_id=target_id, props=props
        )
        record = await result.single()
        if record:
            return {"type": record["type"], "properties": record["props"]}
        return {}


# === Graph Queries ===


async def get_investigation_graph(
    root_entity_id: str,
    max_depth: int = 3,
    limit: int = 500,
) -> dict[str, Any]:
    """Get the full subgraph reachable from a root entity up to max_depth hops."""
    # Cypher doesn't support parameters in variable-length patterns,
    # so we interpolate max_depth directly (it's always an int from our code)
    query = f"""
    MATCH path = (root {{id: $root_id}})-[*0..{int(max_depth)}]-(connected)
    WITH DISTINCT connected, path
    LIMIT $limit
    WITH collect(DISTINCT connected) AS nodes,
         collect(DISTINCT path) AS paths
    UNWIND nodes AS n
    WITH collect(DISTINCT {{
        id: n.id,
        labels: labels(n),
        properties: properties(n)
    }}) AS entities, paths
    UNWIND paths AS p
    UNWIND relationships(p) AS r
    WITH entities, collect(DISTINCT {{
        id: id(r),
        type: type(r),
        source_id: startNode(r).id,
        target_id: endNode(r).id,
        properties: properties(r)
    }}) AS relationships
    RETURN entities, relationships
    """
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(
            query, root_id=root_entity_id, limit=limit
        )
        record = await result.single()
        if record:
            return {
                "entities": record["entities"],
                "relationships": record["relationships"],
            }
        return {"entities": [], "relationships": []}


async def get_entity_neighborhood(
    entity_id: str,
    depth: int = 1,
) -> dict[str, Any]:
    """Get an entity and its N-hop neighborhood."""
    query = f"""
    MATCH (center {{id: $id}})
    OPTIONAL MATCH path = (center)-[*1..{int(depth)}]-(neighbor)
    WITH center, collect(DISTINCT neighbor) AS neighbors,
         collect(DISTINCT relationships(path)) AS all_rels
    UNWIND all_rels AS rels
    UNWIND rels AS r
    RETURN {{
        id: center.id,
        labels: labels(center),
        properties: properties(center)
    }} AS center,
    [n IN neighbors | {{
        id: n.id,
        labels: labels(n),
        properties: properties(n)
    }}] AS neighbors,
    collect(DISTINCT {{
        type: type(r),
        source_id: startNode(r).id,
        target_id: endNode(r).id,
        properties: properties(r)
    }}) AS relationships
    """
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(query, id=entity_id)
        record = await result.single()
        if record:
            return {
                "center": record["center"],
                "neighbors": record["neighbors"],
                "relationships": record["relationships"],
            }
        return {"center": None, "neighbors": [], "relationships": []}


async def fulltext_search(
    query_text: str,
    entity_types: list[EntityType] | None = None,
    limit: int = 20,
) -> list[dict[str, Any]]:
    """Full-text search across entity names."""
    # Try person, business, address indexes
    results: list[dict[str, Any]] = []

    indexes = [
        ("person_fulltext", EntityType.PERSON),
        ("business_fulltext", EntityType.BUSINESS),
        ("address_fulltext", EntityType.ADDRESS),
        ("case_fulltext", EntityType.CASE),
    ]

    driver = await get_driver()
    async with driver.session() as session:
        for index_name, etype in indexes:
            if entity_types and etype not in entity_types:
                continue

            search_query = (
                f"CALL db.index.fulltext.queryNodes('{index_name}', $query) "
                f"YIELD node, score "
                f"RETURN node.id AS id, labels(node) AS labels, "
                f"properties(node) AS properties, score "
                f"ORDER BY score DESC LIMIT $limit"
            )
            try:
                result = await session.run(
                    search_query, query=query_text, limit=limit
                )
                async for record in result:
                    results.append({
                        "id": record["id"],
                        "labels": record["labels"],
                        "properties": record["properties"],
                        "score": record["score"],
                    })
            except Exception:
                # Index may not exist yet
                logger.debug("Fulltext index %s not available", index_name)
                continue

    # Sort by score and deduplicate
    results.sort(key=lambda r: r["score"], reverse=True)
    return results[:limit]


async def find_path(
    source_id: str,
    target_id: str,
    max_depth: int = 6,
) -> list[dict[str, Any]]:
    """Find shortest path between two entities."""
    query = """
    MATCH path = shortestPath(
        (a {id: $source_id})-[*..{max_depth}]-(b {id: $target_id})
    )
    RETURN [n IN nodes(path) | {
        id: n.id,
        labels: labels(n),
        properties: properties(n)
    }] AS nodes,
    [r IN relationships(path) | {
        type: type(r),
        source_id: startNode(r).id,
        target_id: endNode(r).id,
        properties: properties(r)
    }] AS relationships
    """.replace("{max_depth}", str(max_depth))

    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(
            query, source_id=source_id, target_id=target_id
        )
        record = await result.single()
        if record:
            return {
                "nodes": record["nodes"],
                "relationships": record["relationships"],
            }
        return {"nodes": [], "relationships": []}


async def get_entity_count() -> int:
    """Get total number of entities."""
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run("MATCH (n) RETURN count(n) AS count")
        record = await result.single()
        return record["count"] if record else 0


async def get_relationship_count() -> int:
    """Get total number of relationships."""
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run("MATCH ()-[r]->() RETURN count(r) AS count")
        record = await result.single()
        return record["count"] if record else 0


def _serialize_props(props: dict[str, Any]) -> dict[str, Any]:
    """Convert Python types to Neo4j-compatible types."""
    serialized = {}
    for key, value in props.items():
        if isinstance(value, UUID):
            serialized[key] = str(value)
        elif isinstance(value, list):
            serialized[key] = [str(v) if isinstance(v, UUID) else v for v in value]
        elif value is not None:
            serialized[key] = value
    return serialized
