"""Tests for conflict resolution."""

from app.enrichment.conflict_resolver import (
    ConflictedValue,
    detect_conflicts,
    get_source_priority,
    resolve_attribute,
)


def test_resolve_single_value() -> None:
    values = [ConflictedValue(value="John", source="census", confidence=0.9)]
    resolved, strategy = resolve_attribute("name", values)
    assert resolved == "John"
    assert strategy == "single_source"


def test_resolve_unanimous() -> None:
    values = [
        ConflictedValue(value="John", source="census", confidence=0.9),
        ConflictedValue(value="john", source="qpublic", confidence=0.8),
    ]
    resolved, strategy = resolve_attribute("name", values)
    assert resolved == "John"
    assert strategy == "unanimous"


def test_resolve_highest_confidence() -> None:
    values = [
        ConflictedValue(value="John", source="census", confidence=0.9),
        ConflictedValue(value="Jonathan", source="qpublic", confidence=0.7),
    ]
    resolved, strategy = resolve_attribute("name", values, strategy="highest_confidence")
    assert resolved == "John"
    assert strategy == "highest_confidence"


def test_resolve_source_priority() -> None:
    values = [
        ConflictedValue(value="123 Main St", source="nominatim", confidence=0.9),
        ConflictedValue(value="123 Main Street", source="census_geocoder", confidence=0.8),
    ]
    resolved, strategy = resolve_attribute("address", values, strategy="source_priority")
    assert resolved == "123 Main Street"  # Census outranks Nominatim
    assert strategy == "source_priority"


def test_resolve_newest_wins() -> None:
    values = [
        ConflictedValue(value="Active", source="sos", confidence=0.8, retrieved_at="2024-01-01"),
        ConflictedValue(value="Dissolved", source="sos", confidence=0.8, retrieved_at="2025-06-15"),
    ]
    resolved, strategy = resolve_attribute("status", values, strategy="newest_wins")
    assert resolved == "Dissolved"
    assert strategy == "newest_wins"


def test_resolve_no_values() -> None:
    resolved, strategy = resolve_attribute("name", [])
    assert resolved is None
    assert strategy == "no_values"


def test_resolve_all_null() -> None:
    values = [
        ConflictedValue(value=None, source="a", confidence=0.5),
        ConflictedValue(value=None, source="b", confidence=0.5),
    ]
    resolved, strategy = resolve_attribute("name", values)
    assert resolved is None
    assert strategy == "all_null"


def test_detect_conflicts_finds_disagreement() -> None:
    provenance = [
        {"attribute_name": "full_name", "attribute_value": "John", "connector_name": "census", "confidence_score": 0.9},
        {"attribute_name": "full_name", "attribute_value": "Jonathan", "connector_name": "qpublic", "confidence_score": 0.7},
        {"attribute_name": "state", "attribute_value": "GA", "connector_name": "census", "confidence_score": 0.9},
        {"attribute_name": "state", "attribute_value": "GA", "connector_name": "qpublic", "confidence_score": 0.8},
    ]
    report = detect_conflicts("entity-123", provenance)
    assert len(report.conflicts) == 1
    assert report.conflicts[0].attribute == "full_name"
    assert report.conflicts[0].resolved_value == "John"


def test_detect_conflicts_no_disagreement() -> None:
    provenance = [
        {"attribute_name": "state", "attribute_value": "GA", "connector_name": "a", "confidence_score": 0.9},
        {"attribute_name": "state", "attribute_value": "GA", "connector_name": "b", "confidence_score": 0.8},
    ]
    report = detect_conflicts("entity-123", provenance)
    assert len(report.conflicts) == 0


def test_source_priority() -> None:
    assert get_source_priority("census_geocoder") > get_source_priority("nominatim")
    assert get_source_priority("gwinnett_courts") > get_source_priority("google_places")
    assert get_source_priority("unknown_source") == 50
