"""Conflict resolution — handle contradictory data from multiple sources.

When multiple connectors return different values for the same attribute,
this module decides which value to display while preserving all alternatives
in the provenance layer.

Strategies:
  highest_confidence: Pick the value from the highest-confidence source.
  newest_wins:        Pick the most recently retrieved value.
  source_priority:    Government sources outrank commercial sources.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)

# Source priority tiers (higher = more trusted)
SOURCE_PRIORITY: dict[str, int] = {
    # Government / official
    "census_geocoder": 95,
    "census_data": 95,
    "fbi_crime": 90,
    "epa_echo": 90,
    "openfema": 90,
    "nhtsa_vpic": 90,
    # Court / legal
    "courtlistener": 85,
    "gwinnett_courts": 85,
    "gsccca_deeds": 85,
    # County records
    "gwinnett_parcel": 80,
    "qpublic": 80,
    "ga_secretary_state": 80,
    "gbi_sex_offender": 80,
    "gwinnett_sheriff_jail": 80,
    # Open data / community
    "nominatim": 70,
    "opencorporates": 70,
    # Commercial / limited
    "sec_edgar": 75,
    "google_places": 60,
    "hunter_io": 60,
    "numverify": 60,
}

DEFAULT_PRIORITY = 50


@dataclass
class ConflictedValue:
    """A single value with its source metadata."""

    value: Any
    source: str
    confidence: float
    retrieved_at: str | None = None


@dataclass
class ConflictReport:
    """Report of conflicts found for an entity."""

    entity_id: str
    conflicts: list[AttributeConflict] = field(default_factory=list)


@dataclass
class AttributeConflict:
    """A conflict on a specific attribute."""

    attribute: str
    values: list[ConflictedValue]
    resolved_value: Any = None
    resolution_strategy: str = ""


def resolve_attribute(
    attribute: str,
    values: list[ConflictedValue],
    strategy: str = "highest_confidence",
) -> tuple[Any, str]:
    """Resolve a conflict for a single attribute.

    Args:
        attribute: The attribute name.
        values: List of conflicting values with source metadata.
        strategy: Resolution strategy to use.

    Returns:
        Tuple of (resolved_value, strategy_used).
    """
    if not values:
        return None, "no_values"
    if len(values) == 1:
        return values[0].value, "single_source"

    # Filter out None values
    non_null = [v for v in values if v.value is not None]
    if not non_null:
        return None, "all_null"
    if len(non_null) == 1:
        return non_null[0].value, "single_non_null"

    # Check if all values agree
    unique_values = set(str(v.value).lower().strip() for v in non_null)
    if len(unique_values) == 1:
        return non_null[0].value, "unanimous"

    # Actual conflict — apply strategy
    if strategy == "highest_confidence":
        winner = max(non_null, key=lambda v: v.confidence)
        return winner.value, "highest_confidence"

    elif strategy == "source_priority":
        winner = max(
            non_null,
            key=lambda v: SOURCE_PRIORITY.get(v.source, DEFAULT_PRIORITY),
        )
        return winner.value, "source_priority"

    elif strategy == "newest_wins":
        winner = max(
            non_null,
            key=lambda v: v.retrieved_at or "",
        )
        return winner.value, "newest_wins"

    elif strategy == "weighted":
        # Combine confidence × source_priority
        winner = max(
            non_null,
            key=lambda v: v.confidence * SOURCE_PRIORITY.get(v.source, DEFAULT_PRIORITY),
        )
        return winner.value, "weighted"

    # Default fallback
    winner = max(non_null, key=lambda v: v.confidence)
    return winner.value, "fallback_confidence"


def detect_conflicts(
    entity_id: str,
    provenance_records: list[dict[str, Any]],
) -> ConflictReport:
    """Detect attribute conflicts from provenance records.

    Groups provenance records by attribute_name and checks for disagreements.

    Args:
        entity_id: The entity to check.
        provenance_records: List of source_records from PostgreSQL.

    Returns:
        ConflictReport with all detected conflicts.
    """
    # Group by attribute name
    by_attribute: dict[str, list[ConflictedValue]] = {}

    for record in provenance_records:
        attr_name = record.get("attribute_name")
        if not attr_name:
            continue

        value = record.get("attribute_value")
        source = record.get("connector_name", "unknown")
        confidence = record.get("confidence_score", 0.5)
        retrieved = str(record.get("retrieval_date", ""))

        if attr_name not in by_attribute:
            by_attribute[attr_name] = []

        by_attribute[attr_name].append(
            ConflictedValue(
                value=value,
                source=source,
                confidence=confidence,
                retrieved_at=retrieved,
            )
        )

    # Find attributes with conflicting values
    report = ConflictReport(entity_id=entity_id)

    for attr_name, values in by_attribute.items():
        if len(values) < 2:
            continue

        # Check if values actually disagree
        unique = set(str(v.value).lower().strip() for v in values if v.value is not None)
        if len(unique) <= 1:
            continue

        # Real conflict
        resolved_value, strategy = resolve_attribute(attr_name, values)

        report.conflicts.append(
            AttributeConflict(
                attribute=attr_name,
                values=values,
                resolved_value=resolved_value,
                resolution_strategy=strategy,
            )
        )

    if report.conflicts:
        logger.info(
            "Entity %s has %d attribute conflicts",
            entity_id[:8],
            len(report.conflicts),
        )

    return report


def get_source_priority(connector_name: str) -> int:
    """Get the trust priority for a source (higher = more trusted)."""
    return SOURCE_PRIORITY.get(connector_name, DEFAULT_PRIORITY)
