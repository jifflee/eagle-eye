"""Relationship type definitions for the entity graph."""

from __future__ import annotations

import enum
from datetime import date, datetime
from uuid import UUID, uuid4

from pydantic import BaseModel, Field


class RelationshipType(str, enum.Enum):
    LIVES_AT = "LIVES_AT"
    OWNS_PROPERTY = "OWNS_PROPERTY"
    IS_RELATIVE_OF = "IS_RELATIVE_OF"
    WORKS_FOR = "WORKS_FOR"
    OWNS_BUSINESS = "OWNS_BUSINESS"
    NAMED_IN_CASE = "NAMED_IN_CASE"
    REGISTERED_VEHICLE = "REGISTERED_VEHICLE"
    HAS_SOCIAL_PROFILE = "HAS_SOCIAL_PROFILE"
    HAS_PHONE = "HAS_PHONE"
    HAS_EMAIL = "HAS_EMAIL"
    LOCATED_AT = "LOCATED_AT"
    AFFILIATED_WITH = "AFFILIATED_WITH"
    IN_CENSUS_TRACT = "IN_CENSUS_TRACT"
    HAS_CRIME_NEAR = "HAS_CRIME_NEAR"
    HAS_ENV_FACILITY = "HAS_ENV_FACILITY"


class Relationship(BaseModel):
    id: UUID = Field(default_factory=uuid4)
    source_id: UUID
    target_id: UUID
    relationship_type: RelationshipType
    properties: RelationshipProperties = Field(default_factory=lambda: RelationshipProperties())
    created_at: datetime = Field(default_factory=datetime.utcnow)


class RelationshipProperties(BaseModel):
    """Common properties carried on all relationship edges."""

    from_date: date | None = None
    to_date: date | None = None
    confidence: float = 0.5
    verified: bool = False
    sources: list[str] = Field(default_factory=list)

    # Type-specific optional fields
    relationship_subtype: str | None = None  # e.g., "spouse", "sibling" for IS_RELATIVE_OF
    party_type: str | None = None  # e.g., "plaintiff", "defendant" for NAMED_IN_CASE
    role: str | None = None  # e.g., "Managing Member" for OWNS_BUSINESS
    ownership_pct: float | None = None  # for OWNS_PROPERTY, OWNS_BUSINESS
    office_type: str | None = None  # e.g., "headquarters" for LOCATED_AT
    distance_meters: float | None = None  # for HAS_CRIME_NEAR, HAS_ENV_FACILITY
    primary: bool | None = None  # for HAS_PHONE, HAS_EMAIL
