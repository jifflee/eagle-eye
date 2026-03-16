"""Tests for entity deduplication."""

from app.enrichment.deduplicator import (
    address_similarity,
    find_duplicate_businesses,
    find_duplicate_persons,
    merge_entity_attributes,
    name_similarity,
    normalize_name,
)


def test_normalize_name_strips_suffix() -> None:
    assert normalize_name("Acme Inc") == "acme"
    assert normalize_name("Acme Inc.") == "acme"
    assert normalize_name("Smith Consulting LLC") == "smith consulting"
    assert normalize_name("Johnson Corp.") == "johnson"


def test_normalize_name_strips_punctuation() -> None:
    assert normalize_name("O'Brien") == "obrien"
    assert normalize_name("Smith-Johnson") == "smithjohnson"


def test_name_similarity_exact() -> None:
    assert name_similarity("John Doe", "John Doe") == 1.0


def test_name_similarity_case_insensitive() -> None:
    assert name_similarity("john doe", "JOHN DOE") == 1.0


def test_name_similarity_close_match() -> None:
    sim = name_similarity("John Doe", "John A Doe")
    assert sim > 0.8


def test_name_similarity_different() -> None:
    sim = name_similarity("John Doe", "Jane Smith")
    assert sim < 0.5


def test_address_similarity_exact() -> None:
    assert address_similarity("123 Main St", "123 Main St") == 1.0


def test_address_similarity_abbreviations() -> None:
    sim = address_similarity("123 Main Street", "123 Main St")
    assert sim == 1.0


def test_find_duplicate_persons() -> None:
    entities = [
        {"id": "1", "type": "PERSON", "full_name": "John Doe"},
        {"id": "2", "type": "PERSON", "full_name": "JOHN DOE"},
        {"id": "3", "type": "PERSON", "full_name": "Jane Smith"},
    ]
    groups = find_duplicate_persons(entities)
    assert len(groups) == 1
    assert groups[0].primary_id == "1"
    assert "2" in groups[0].duplicate_ids


def test_find_duplicate_persons_with_middle_name() -> None:
    entities = [
        {"id": "1", "type": "PERSON", "full_name": "John Doe"},
        {"id": "2", "type": "PERSON", "full_name": "John A Doe"},
    ]
    groups = find_duplicate_persons(entities)
    assert len(groups) == 1


def test_find_no_duplicates() -> None:
    entities = [
        {"id": "1", "type": "PERSON", "full_name": "John Doe"},
        {"id": "2", "type": "PERSON", "full_name": "Jane Smith"},
    ]
    groups = find_duplicate_persons(entities)
    assert len(groups) == 0


def test_find_duplicate_businesses() -> None:
    entities = [
        {"id": "1", "type": "BUSINESS", "name": "Acme Inc"},
        {"id": "2", "type": "BUSINESS", "name": "ACME, INC."},
        {"id": "3", "type": "BUSINESS", "name": "Totally Different Co"},
    ]
    groups = find_duplicate_businesses(entities)
    assert len(groups) == 1
    assert groups[0].primary_id == "1"


def test_merge_attributes_fills_gaps() -> None:
    primary = {"id": "1", "name": "John", "phone": None}
    duplicate = {"id": "2", "name": "John Doe", "phone": "555-1234", "email": "john@test.com"}
    merged = merge_entity_attributes(primary, duplicate)
    assert merged["name"] == "John"  # Primary keeps its value
    assert merged["phone"] == "555-1234"  # Filled from duplicate
    assert merged["email"] == "john@test.com"  # New attribute from duplicate


def test_merge_attributes_unions_lists() -> None:
    primary = {"id": "1", "aliases": ["Johnny"]}
    duplicate = {"id": "2", "aliases": ["Johnny", "JD"]}
    merged = merge_entity_attributes(primary, duplicate)
    assert set(merged["aliases"]) == {"Johnny", "JD"}
