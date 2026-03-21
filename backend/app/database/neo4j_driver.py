"""Neo4j database driver — async connection pool and graph operations."""

from __future__ import annotations

import logging
from typing import Any
from uuid import UUID

from neo4j import AsyncGraphDatabase, AsyncDriver

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
    label = "".join(word.capitalize() for word in entity_type.value.split("_"))
    props = _serialize_props(properties)
    query = f"CREATE (n:{label} $props) RETURN n"
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(query, props=props)
        record = await result.single()
        return dict(record["n"]) if record else {}


async def get_entity(entity_id: str) -> dict[str, Any] | None:
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
    """Get the full subgraph reachable from a root entity."""
    depth = int(max_depth)
    driver = await get_driver()

    async with driver.session() as session:
        # Step 1: Get all reachable node IDs
        id_query = (
            "MATCH (root {id: $root_id}) "
            f"OPTIONAL MATCH (root)-[*0..{depth}]-(n) "
            "RETURN collect(DISTINCT n.id) AS ids"
        )
        result = await session.run(id_query, root_id=root_entity_id)
        record = await result.single()
        node_ids = record["ids"] if record else []

        if not node_ids:
            return {"entities": [], "relationships": []}

        # Step 2: Get entity details
        entity_query = (
            "MATCH (n) WHERE n.id IN $ids "
            "RETURN n.id AS id, labels(n) AS labels, properties(n) AS properties"
        )
        result = await session.run(entity_query, ids=node_ids)
        entities = []
        async for rec in result:
            entities.append({
                "id": rec["id"],
                "labels": rec["labels"],
                "properties": rec["properties"],
            })

        # Step 3: Get relationships between these nodes
        rel_query = (
            "MATCH (a)-[r]->(b) "
            "WHERE a.id IN $ids AND b.id IN $ids "
            "RETURN id(r) AS id, type(r) AS type, a.id AS source_id, b.id AS target_id, properties(r) AS properties"
        )
        result = await session.run(rel_query, ids=node_ids)
        relationships = []
        async for rec in result:
            relationships.append({
                "id": rec["id"],
                "type": rec["type"],
                "source_id": rec["source_id"],
                "target_id": rec["target_id"],
                "properties": rec["properties"],
            })

        logger.info("Graph: %d entities, %d relationships for root %s", len(entities), len(relationships), root_entity_id[:8])
        return {"entities": entities, "relationships": relationships}


async def get_entity_neighborhood(
    entity_id: str,
    depth: int = 1,
) -> dict[str, Any]:
    """Get an entity and its N-hop neighborhood."""
    d = int(depth)
    driver = await get_driver()
    async with driver.session() as session:
        query = (
            "MATCH (center {id: $id}) "
            f"OPTIONAL MATCH (center)-[*1..{d}]-(n) "
            "WITH center, collect(DISTINCT n) AS neighbors "
            "RETURN center.id AS center_id, labels(center) AS center_labels, properties(center) AS center_props, "
            "[n IN neighbors | {id: n.id, labels: labels(n), properties: properties(n)}] AS neighbors"
        )
        result = await session.run(query, id=entity_id)
        record = await result.single()
        if not record:
            return {"center": None, "neighbors": [], "relationships": []}

        center = {"id": record["center_id"], "labels": record["center_labels"], "properties": record["center_props"]}
        neighbors = record["neighbors"]

        # Get relationships
        all_ids = [center["id"]] + [n["id"] for n in neighbors if n.get("id")]
        rel_query = (
            "MATCH (a)-[r]->(b) WHERE a.id IN $ids AND b.id IN $ids "
            "RETURN type(r) AS type, a.id AS source_id, b.id AS target_id, properties(r) AS properties"
        )
        result = await session.run(rel_query, ids=all_ids)
        relationships = []
        async for rec in result:
            relationships.append({
                "type": rec["type"],
                "source_id": rec["source_id"],
                "target_id": rec["target_id"],
                "properties": rec["properties"],
            })

        return {"center": center, "neighbors": neighbors, "relationships": relationships}


async def fulltext_search(
    query_text: str,
    entity_types: list[EntityType] | None = None,
    limit: int = 20,
) -> list[dict[str, Any]]:
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
                result = await session.run(search_query, query=query_text, limit=limit)
                async for record in result:
                    results.append({
                        "id": record["id"],
                        "labels": record["labels"],
                        "properties": record["properties"],
                        "score": record["score"],
                    })
            except Exception:
                logger.debug("Fulltext index %s not available", index_name)
    results.sort(key=lambda r: r["score"], reverse=True)
    return results[:limit]


async def find_path(
    source_id: str,
    target_id: str,
    max_depth: int = 6,
) -> dict[str, Any]:
    d = int(max_depth)
    query = (
        f"MATCH path = shortestPath((a {{id: $source_id}})-[*..{d}]-(b {{id: $target_id}})) "
        "RETURN [n IN nodes(path) | {id: n.id, labels: labels(n), properties: properties(n)}] AS nodes, "
        "[r IN relationships(path) | {type: type(r), source_id: startNode(r).id, target_id: endNode(r).id, properties: properties(r)}] AS relationships"
    )
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run(query, source_id=source_id, target_id=target_id)
        record = await result.single()
        if record:
            return {"nodes": record["nodes"], "relationships": record["relationships"]}
        return {"nodes": [], "relationships": []}


async def get_entity_count() -> int:
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run("MATCH (n) RETURN count(n) AS count")
        record = await result.single()
        return record["count"] if record else 0


async def get_relationship_count() -> int:
    driver = await get_driver()
    async with driver.session() as session:
        result = await session.run("MATCH ()-[r]->() RETURN count(r) AS count")
        record = await result.single()
        return record["count"] if record else 0


def _serialize_props(props: dict[str, Any]) -> dict[str, Any]:
    serialized = {}
    for key, value in props.items():
        if isinstance(value, UUID):
            serialized[key] = str(value)
        elif isinstance(value, list):
            serialized[key] = [str(v) if isinstance(v, UUID) else v for v in value]
        elif value is not None:
            serialized[key] = value
    return serialized
