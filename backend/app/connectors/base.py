"""Abstract base class for all OSINT data source connectors."""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any

from app.models.entities import AnyEntity, BaseEntity, EntityType

logger = logging.getLogger(__name__)


@dataclass
class RateLimit:
    """Rate limit configuration for a connector."""

    requests_per_second: float = 1.0
    requests_per_minute: float = 60.0
    burst_size: int = 5


@dataclass
class ConnectorResult:
    """Result from a connector discover or enrich call."""

    entities: list[dict[str, Any]] = field(default_factory=list)
    relationships: list[dict[str, Any]] = field(default_factory=list)
    raw_data: dict[str, Any] | None = None
    error: str | None = None
    source_name: str = ""
    confidence: float = 0.5


class BaseConnector(ABC):
    """Abstract base for all OSINT data source connectors.

    Every connector must implement:
    - discover(): Find related entities given an input entity
    - enrich(): Add attributes to an existing entity
    - validate(): Check if the connector is operational

    Connectors are auto-discovered by the registry when placed in
    the appropriate tier directory (tier1/, tier2/, tier3/).
    """

    # Subclasses must set these
    name: str = ""
    description: str = ""
    tier: int = 1  # 1=free no-auth, 2=free registration/scraping, 3=limited free
    requires_auth: bool = False
    rate_limit: RateLimit = RateLimit()
    default_confidence: float = 0.7

    # Entity types this connector can discover FROM
    supported_input_types: list[EntityType] = []
    # Entity types this connector can produce
    supported_output_types: list[EntityType] = []

    def __init__(self) -> None:
        self.logger = logging.getLogger(f"connector.{self.name}")

    @abstractmethod
    async def discover(self, entity: dict[str, Any]) -> ConnectorResult:
        """Find related entities given an input entity.

        For example, given an ADDRESS entity, a property records connector
        might discover PERSON entities (residents/owners) and PROPERTY entities.

        Args:
            entity: Dict with 'id', 'type', and entity-specific attributes.

        Returns:
            ConnectorResult with discovered entities and relationships.
        """
        ...

    @abstractmethod
    async def enrich(self, entity: dict[str, Any]) -> ConnectorResult:
        """Add attributes and relationships to an existing entity.

        For example, given a PERSON entity, a court records connector
        might add court CASE entities as relationships.

        Args:
            entity: Dict with 'id', 'type', and existing attributes.

        Returns:
            ConnectorResult with enriched data.
        """
        ...

    async def validate(self) -> bool:
        """Check if the connector is operational (API reachable, auth valid).

        Returns:
            True if the connector can make requests.
        """
        return True

    def can_discover_from(self, entity_type: EntityType) -> bool:
        """Check if this connector supports discovery from a given entity type."""
        return entity_type in self.supported_input_types

    def can_produce(self, entity_type: EntityType) -> bool:
        """Check if this connector can produce a given entity type."""
        return entity_type in self.supported_output_types
