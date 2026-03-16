"""Provenance and source tracking models."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from pydantic import BaseModel, Field


class SourceRecord(BaseModel):
    """Tracks the origin of every piece of data in the system."""

    id: UUID = Field(default_factory=uuid4)
    entity_id: UUID
    investigation_id: UUID | None = None
    connector_name: str
    confidence_score: float = 0.5
    data_quality_flags: list[str] = Field(default_factory=list)
    retrieval_date: datetime = Field(default_factory=datetime.utcnow)
    expiration_date: datetime | None = None
    raw_data: dict | None = None
    attribute_name: str | None = None
    attribute_value: str | None = None
    attribute_hash: str | None = None


class ConnectorStatus(BaseModel):
    """Tracks the status of each connector during an investigation."""

    id: UUID = Field(default_factory=uuid4)
    investigation_id: UUID
    connector_name: str
    status: ConnectorState = "pending"
    started_at: datetime | None = None
    completed_at: datetime | None = None
    entities_found: int = 0
    error_message: str | None = None
    retry_count: int = 0
    next_retry_at: datetime | None = None


ConnectorState = str  # pending, running, complete, failed, rate_limited, cancelled
