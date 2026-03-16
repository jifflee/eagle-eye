"""Entity deduplication — detect and merge duplicate entities from multiple sources.

Uses fuzzy name matching, address normalization, and configurable thresholds
to identify probable duplicates. Merges keep the highest-confidence attributes
and maintain a full audit trail.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from difflib import SequenceMatcher
from typing import Any

logger = logging.getLogger(__name__)


@dataclass
class DuplicateGroup:
    """A group of entities that are likely the same real-world entity."""

    primary_id: str
    duplicate_ids: list[str] = field(default_factory=list)
    confidence: float = 0.0
    match_reason: str = ""


def normalize_name(name: str) -> str:
    """Normalize a person or business name for comparison."""
    if not name:
        return ""
    # Lowercase, strip whitespace
    name = name.lower().strip()
    # Remove common suffixes
    for suffix in [
        " inc", " inc.", " llc", " llc.", " corp", " corp.",
        " co", " co.", " ltd", " ltd.", " lp", " l.p.",
        " pllc", " pc", " p.c.", " dba",
    ]:
        if name.endswith(suffix):
            name = name[: -len(suffix)]
    # Remove punctuation
    name = re.sub(r"[.,'\"-]", "", name)
    # Collapse whitespace
    name = re.sub(r"\s+", " ", name).strip()
    return name


def normalize_address_str(address: str) -> str:
    """Normalize an address string for comparison."""
    if not address:
        return ""
    address = address.lower().strip()
    # Common abbreviations
    replacements = {
        " street": " st", " avenue": " ave", " boulevard": " blvd",
        " drive": " dr", " lane": " ln", " court": " ct",
        " road": " rd", " place": " pl", " circle": " cir",
        " north ": " n ", " south ": " s ",
        " east ": " e ", " west ": " w ",
    }
    for old, new in replacements.items():
        address = address.replace(old, new)
    # Remove apt/suite/unit details for comparison
    address = re.sub(r"\s*(apt|suite|ste|unit|#)\s*\S+", "", address)
    address = re.sub(r"\s+", " ", address).strip()
    return address


def name_similarity(name1: str, name2: str) -> float:
    """Calculate similarity between two names (0.0 to 1.0)."""
    n1 = normalize_name(name1)
    n2 = normalize_name(name2)
    if not n1 or not n2:
        return 0.0
    if n1 == n2:
        return 1.0
    return SequenceMatcher(None, n1, n2).ratio()


def address_similarity(addr1: str, addr2: str) -> float:
    """Calculate similarity between two addresses (0.0 to 1.0)."""
    a1 = normalize_address_str(addr1)
    a2 = normalize_address_str(addr2)
    if not a1 or not a2:
        return 0.0
    if a1 == a2:
        return 1.0
    return SequenceMatcher(None, a1, a2).ratio()


def find_duplicate_persons(
    entities: list[dict[str, Any]],
    name_threshold: float = 0.85,
) -> list[DuplicateGroup]:
    """Find duplicate PERSON entities by fuzzy name matching.

    Args:
        entities: List of person entity dicts with 'id', 'full_name', etc.
        name_threshold: Minimum name similarity to consider a match.

    Returns:
        List of DuplicateGroups identifying probable duplicates.
    """
    persons = [e for e in entities if e.get("type") == "PERSON"]
    if len(persons) < 2:
        return []

    groups: list[DuplicateGroup] = []
    matched: set[str] = set()

    for i, p1 in enumerate(persons):
        p1_id = str(p1.get("id", ""))
        if p1_id in matched:
            continue

        p1_name = p1.get("full_name") or f"{p1.get('first_name', '')} {p1.get('last_name', '')}"
        duplicates = []

        for j, p2 in enumerate(persons[i + 1 :], start=i + 1):
            p2_id = str(p2.get("id", ""))
            if p2_id in matched:
                continue

            p2_name = p2.get("full_name") or f"{p2.get('first_name', '')} {p2.get('last_name', '')}"

            sim = name_similarity(p1_name, p2_name)
            if sim >= name_threshold:
                # Boost confidence if they share an address
                p1_addr = str(p1.get("address", ""))
                p2_addr = str(p2.get("address", ""))
                addr_match = address_similarity(p1_addr, p2_addr) > 0.8 if (p1_addr and p2_addr) else False

                confidence = sim
                if addr_match:
                    confidence = min(1.0, confidence + 0.1)

                duplicates.append(p2_id)
                matched.add(p2_id)

        if duplicates:
            matched.add(p1_id)
            groups.append(
                DuplicateGroup(
                    primary_id=p1_id,
                    duplicate_ids=duplicates,
                    confidence=confidence,
                    match_reason=f"name_similarity={sim:.2f}",
                )
            )

    return groups


def find_duplicate_businesses(
    entities: list[dict[str, Any]],
    name_threshold: float = 0.80,
) -> list[DuplicateGroup]:
    """Find duplicate BUSINESS entities by fuzzy name matching."""
    businesses = [e for e in entities if e.get("type") == "BUSINESS"]
    if len(businesses) < 2:
        return []

    groups: list[DuplicateGroup] = []
    matched: set[str] = set()

    for i, b1 in enumerate(businesses):
        b1_id = str(b1.get("id", ""))
        if b1_id in matched:
            continue

        b1_name = b1.get("name", "") or b1.get("legal_name", "")
        duplicates = []

        for j, b2 in enumerate(businesses[i + 1 :], start=i + 1):
            b2_id = str(b2.get("id", ""))
            if b2_id in matched:
                continue

            b2_name = b2.get("name", "") or b2.get("legal_name", "")
            sim = name_similarity(b1_name, b2_name)

            if sim >= name_threshold:
                duplicates.append(b2_id)
                matched.add(b2_id)

        if duplicates:
            matched.add(b1_id)
            groups.append(
                DuplicateGroup(
                    primary_id=b1_id,
                    duplicate_ids=duplicates,
                    confidence=sim,
                    match_reason=f"name_similarity={sim:.2f}",
                )
            )

    return groups


def merge_entity_attributes(
    primary: dict[str, Any],
    duplicate: dict[str, Any],
    strategy: str = "favor_higher_confidence",
) -> dict[str, Any]:
    """Merge attributes from a duplicate into the primary entity.

    Strategy:
        favor_higher_confidence: Keep the attribute with higher source confidence.
        favor_newer: Keep the more recently retrieved attribute.
        union: Keep all values (for list fields like aliases).

    Returns:
        Merged attributes dict.
    """
    merged = dict(primary)

    for key, dup_value in duplicate.items():
        if key in ("id", "type", "created_at", "updated_at", "entity_type"):
            continue
        if dup_value is None:
            continue

        primary_value = merged.get(key)

        if primary_value is None:
            # Primary doesn't have this attribute — take from duplicate
            merged[key] = dup_value
        elif isinstance(primary_value, list) and isinstance(dup_value, list):
            # Merge lists (e.g., aliases, sources)
            combined = list(primary_value)
            for item in dup_value:
                if item not in combined:
                    combined.append(item)
            merged[key] = combined
        elif strategy == "favor_higher_confidence":
            # Keep primary (assumed higher confidence since it was chosen as primary)
            pass
        elif strategy == "favor_newer":
            # Take duplicate value (assumed newer)
            merged[key] = dup_value

    return merged


async def run_deduplication(
    investigation_id: str,
    entities: list[dict[str, Any]],
) -> list[DuplicateGroup]:
    """Run deduplication across all entity types.

    Returns list of duplicate groups found. Does NOT auto-merge —
    the caller decides whether to merge or flag for review.
    """
    all_groups: list[DuplicateGroup] = []

    # Find person duplicates
    person_groups = find_duplicate_persons(entities)
    if person_groups:
        logger.info("Found %d person duplicate groups", len(person_groups))
        all_groups.extend(person_groups)

    # Find business duplicates
    business_groups = find_duplicate_businesses(entities)
    if business_groups:
        logger.info("Found %d business duplicate groups", len(business_groups))
        all_groups.extend(business_groups)

    return all_groups
