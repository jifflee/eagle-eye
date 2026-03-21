"""API request/response schemas."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field

from app.models.entities import EntityType
from app.models.relationships import RelationshipType


# === Request Schemas ===


class AddressInput(BaseModel):
    street: str
    city: str
    state: str = Field(max_length=2)
    zip: str = Field(max_length=10)


class InvestigationRequest(BaseModel):
    address: AddressInput
    enrichment_config: EnrichmentConfig | None = None


class EnrichmentConfig(BaseModel):
    tier1_only: bool = False
    selected_sources: list[str] | None = None
    max_depth: int = 3
    max_entities: int = 500


class SearchRequest(BaseModel):
    query: str
    entity_types: list[EntityType] | None = None
    investigation_id: UUID | None = None
    limit: int = Field(default=20, le=100)
    offset: int = 0


class SaveInvestigationRequest(BaseModel):
    name: str
    notes: str | None = None


class EnrichmentControlRequest(BaseModel):
    action: str  # pause, resume, cancel, add_source
    source: str | None = None


# === Response Schemas ===


class EntityResponse(BaseModel):
    id: UUID
    type: EntityType
    label: str
    attributes: dict
    sources: list[SourceInfo] = Field(default_factory=list)


class SourceInfo(BaseModel):
    connector_name: str
    confidence: float
    retrieved_at: datetime


class RelationshipResponse(BaseModel):
    id: int | str | UUID = 0
    source_id: str
    target_id: str
    type: str  # RelationshipType or any string
    properties: dict = {}


class GraphResponse(BaseModel):
    entities: list[EntityResponse]
    relationships: list[RelationshipResponse]


class InvestigationResponse(BaseModel):
    id: UUID
    address: str
    status: str
    graph: GraphResponse
    metadata: InvestigationMetadata


class InvestigationMetadata(BaseModel):
    total_entities: int = 0
    total_relationships: int = 0
    enrichment_status: str = "initializing"
    data_sources_used: list[str] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime


class InvestigationCreatedResponse(BaseModel):
    id: UUID
    status: str = "initializing"
    address: str


class InvestigationSummary(BaseModel):
    id: UUID
    name: str | None
    address: str
    status: str
    entity_count: int
    created_at: datetime
    updated_at: datetime


class SearchResultItem(BaseModel):
    entity_id: UUID
    entity_type: EntityType
    label: str
    snippet: str | None = None
    relevance_score: float = 0.0
    matched_fields: list[str] = Field(default_factory=list)


class SearchResponse(BaseModel):
    results: list[SearchResultItem]
    total: int
    limit: int
    offset: int


class ConnectorStatusResponse(BaseModel):
    connector_name: str
    tier: int
    status: str
    entities_found: int = 0
    error_message: str | None = None
    started_at: datetime | None = None
    completed_at: datetime | None = None


class EnrichmentStatusResponse(BaseModel):
    investigation_id: UUID
    status: str
    started_at: datetime | None = None
    completed_sources: list[str] = Field(default_factory=list)
    in_progress_sources: list[str] = Field(default_factory=list)
    pending_sources: list[str] = Field(default_factory=list)
    failed_sources: list[str] = Field(default_factory=list)
    discovered_entities: int = 0
    connectors: list[ConnectorStatusResponse] = Field(default_factory=list)


class SourceListItem(BaseModel):
    name: str
    tier: int
    requires_auth: bool
    description: str
    status: str  # available, unavailable, rate_limited


class SourceListResponse(BaseModel):
    sources: list[SourceListItem]


class ExportResponse(BaseModel):
    format: str
    data: dict
