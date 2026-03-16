"""PostgreSQL client — provenance, investigations, and audit logging."""

from __future__ import annotations

import json
import logging
from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

import asyncpg

from app.config import settings

logger = logging.getLogger(__name__)

_pool: asyncpg.Pool | None = None


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(
            settings.database_url,
            min_size=2,
            max_size=10,
        )
    return _pool


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


async def check_health() -> bool:
    try:
        pool = await get_pool()
        async with pool.acquire() as conn:
            await conn.fetchval("SELECT 1")
        return True
    except Exception:
        logger.exception("PostgreSQL health check failed")
        return False


# === Investigation Operations ===


async def create_investigation(
    address_street: str,
    address_city: str,
    address_state: str,
    address_zip: str,
    name: str | None = None,
    root_entity_id: str | None = None,
) -> dict[str, Any]:
    """Create a new investigation record."""
    investigation_id = uuid4()
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            INSERT INTO investigations (id, name, address_street, address_city,
                address_state, address_zip, status, root_entity_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            """,
            investigation_id,
            name,
            address_street,
            address_city,
            address_state,
            address_zip,
            "initializing",
            root_entity_id,
        )
    return {
        "id": investigation_id,
        "status": "initializing",
        "address": f"{address_street}, {address_city}, {address_state} {address_zip}",
    }


async def get_investigation(investigation_id: UUID) -> dict[str, Any] | None:
    """Get an investigation by ID."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM investigations WHERE id = $1", investigation_id
        )
        return dict(row) if row else None


async def update_investigation(
    investigation_id: UUID,
    **kwargs: Any,
) -> None:
    """Update investigation fields."""
    if not kwargs:
        return
    set_clauses = []
    values = []
    for i, (key, value) in enumerate(kwargs.items(), start=2):
        set_clauses.append(f"{key} = ${i}")
        values.append(value)

    query = f"UPDATE investigations SET {', '.join(set_clauses)} WHERE id = $1"
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(query, investigation_id, *values)


async def list_investigations(
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """List all investigations, newest first."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT id, name, address_street, address_city, address_state,
                address_zip, status, entity_count, created_at, updated_at
            FROM investigations
            ORDER BY created_at DESC
            LIMIT $1 OFFSET $2
            """,
            limit,
            offset,
        )
        return [dict(row) for row in rows]


async def delete_investigation(investigation_id: UUID) -> bool:
    """Delete an investigation and all related records (cascading)."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        result = await conn.execute(
            "DELETE FROM investigations WHERE id = $1", investigation_id
        )
        return result == "DELETE 1"


# === Provenance (Source Records) Operations ===


async def create_source_record(
    entity_id: str,
    connector_name: str,
    confidence_score: float = 0.5,
    investigation_id: UUID | None = None,
    raw_data: dict | None = None,
    attribute_name: str | None = None,
    attribute_value: str | None = None,
) -> UUID:
    """Record provenance for an entity attribute."""
    record_id = uuid4()
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            INSERT INTO source_records (id, entity_id, investigation_id,
                connector_name, confidence_score, raw_data,
                attribute_name, attribute_value)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            """,
            record_id,
            entity_id,
            investigation_id,
            connector_name,
            confidence_score,
            json.dumps(raw_data) if raw_data else None,
            attribute_name,
            attribute_value,
        )
    return record_id


async def get_entity_provenance(
    entity_id: str,
) -> list[dict[str, Any]]:
    """Get all provenance records for an entity."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT id, connector_name, confidence_score, data_quality_flags,
                retrieval_date, attribute_name, attribute_value
            FROM source_records
            WHERE entity_id = $1
            ORDER BY confidence_score DESC, retrieval_date DESC
            """,
            entity_id,
        )
        return [dict(row) for row in rows]


async def get_provenance_by_source(
    connector_name: str,
    investigation_id: UUID | None = None,
    limit: int = 100,
) -> list[dict[str, Any]]:
    """Get all entities from a specific source."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        if investigation_id:
            rows = await conn.fetch(
                """
                SELECT DISTINCT entity_id, confidence_score, retrieval_date
                FROM source_records
                WHERE connector_name = $1 AND investigation_id = $2
                ORDER BY retrieval_date DESC LIMIT $3
                """,
                connector_name,
                investigation_id,
                limit,
            )
        else:
            rows = await conn.fetch(
                """
                SELECT DISTINCT entity_id, confidence_score, retrieval_date
                FROM source_records
                WHERE connector_name = $1
                ORDER BY retrieval_date DESC LIMIT $2
                """,
                connector_name,
                limit,
            )
        return [dict(row) for row in rows]


# === Connector Status Operations ===


async def upsert_connector_status(
    investigation_id: UUID,
    connector_name: str,
    status: str,
    entities_found: int = 0,
    error_message: str | None = None,
) -> None:
    """Create or update connector status for an investigation."""
    pool = await get_pool()
    now = datetime.utcnow()
    is_terminal = status in ("complete", "failed")
    async with pool.acquire() as conn:
        existing = await conn.fetchrow(
            """
            SELECT id FROM connector_status
            WHERE investigation_id = $1 AND connector_name = $2
            """,
            investigation_id,
            connector_name,
        )
        if existing:
            if is_terminal:
                await conn.execute(
                    """
                    UPDATE connector_status
                    SET status = $3, entities_found = $4, error_message = $5, completed_at = $6
                    WHERE investigation_id = $1 AND connector_name = $2
                    """,
                    investigation_id,
                    connector_name,
                    status,
                    entities_found,
                    error_message,
                    now,
                )
            else:
                await conn.execute(
                    """
                    UPDATE connector_status
                    SET status = $3, entities_found = $4, error_message = $5,
                        started_at = COALESCE(started_at, $6)
                    WHERE investigation_id = $1 AND connector_name = $2
                    """,
                    investigation_id,
                    connector_name,
                    status,
                    entities_found,
                    error_message,
                    now,
                )
        else:
            await conn.execute(
                """
                INSERT INTO connector_status (id, investigation_id, connector_name,
                    status, started_at, entities_found, error_message)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                """,
                uuid4(),
                investigation_id,
                connector_name,
                status,
                now if status == "running" else None,
                entities_found,
                error_message,
            )


async def get_connector_statuses(
    investigation_id: UUID,
) -> list[dict[str, Any]]:
    """Get all connector statuses for an investigation."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT connector_name, status, started_at, completed_at,
                entities_found, error_message, retry_count
            FROM connector_status
            WHERE investigation_id = $1
            ORDER BY connector_name
            """,
            investigation_id,
        )
        return [dict(row) for row in rows]


# === Audit Log Operations ===


async def log_action(
    action: str,
    investigation_id: UUID | None = None,
    entity_id: str | None = None,
    entity_type: str | None = None,
    details: dict | None = None,
) -> None:
    """Append an entry to the audit log."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            INSERT INTO audit_log (id, investigation_id, action,
                entity_id, entity_type, details)
            VALUES ($1, $2, $3, $4, $5, $6)
            """,
            uuid4(),
            investigation_id,
            action,
            entity_id,
            entity_type,
            json.dumps(details) if details else None,
        )


async def get_audit_log(
    investigation_id: UUID | None = None,
    limit: int = 100,
) -> list[dict[str, Any]]:
    """Get audit log entries."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        if investigation_id:
            rows = await conn.fetch(
                """
                SELECT action, entity_id, entity_type, details, created_at
                FROM audit_log
                WHERE investigation_id = $1
                ORDER BY created_at DESC LIMIT $2
                """,
                investigation_id,
                limit,
            )
        else:
            rows = await conn.fetch(
                "SELECT * FROM audit_log ORDER BY created_at DESC LIMIT $1",
                limit,
            )
        return [dict(row) for row in rows]
