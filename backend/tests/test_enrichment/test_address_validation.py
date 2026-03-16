"""Tests for address validation and normalization."""

from app.validation.address_validator import (
    normalize_address,
    normalize_city,
    normalize_state,
    normalize_street,
    normalize_zip,
    validate_address,
)


def test_normalize_street_abbreviations() -> None:
    assert normalize_street("123 main st") == "123 Main Street"
    assert normalize_street("456 oak ave") == "456 Oak Avenue"
    assert normalize_street("789 pine blvd") == "789 Pine Boulevard"


def test_normalize_street_directions() -> None:
    assert normalize_street("100 n main st") == "100 N Main Street"
    assert normalize_street("200 south elm ave") == "200 S Elm Avenue"


def test_normalize_city() -> None:
    assert normalize_city("lawrenceville") == "Lawrenceville"
    assert normalize_city("NEW YORK") == "New York"
    assert normalize_city("san francisco") == "San Francisco"


def test_normalize_state_abbreviation() -> None:
    assert normalize_state("GA") == "GA"
    assert normalize_state("ga") == "GA"
    assert normalize_state("georgia") == "GA"
    assert normalize_state("Georgia") == "GA"


def test_normalize_zip() -> None:
    assert normalize_zip("30043") == "30043"
    assert normalize_zip("30043-1234") == "30043-1234"


def test_normalize_address_full() -> None:
    result = normalize_address(
        street="123 main st",
        city="lawrenceville",
        state="georgia",
        zip_code="30043",
    )
    assert result["street"] == "123 Main Street"
    assert result["city"] == "Lawrenceville"
    assert result["state"] == "GA"
    assert result["zip"] == "30043"


def test_validate_valid_address() -> None:
    errors = validate_address("123 Main St", "Atlanta", "GA", "30303")
    assert errors == []


def test_validate_missing_street() -> None:
    errors = validate_address("", "Atlanta", "GA", "30303")
    assert any("Street" in e for e in errors)


def test_validate_missing_city() -> None:
    errors = validate_address("123 Main St", "", "GA", "30303")
    assert any("City" in e for e in errors)


def test_validate_invalid_state() -> None:
    errors = validate_address("123 Main St", "Atlanta", "XX", "30303")
    assert any("state" in e.lower() for e in errors)


def test_validate_invalid_zip() -> None:
    errors = validate_address("123 Main St", "Atlanta", "GA", "123")
    assert any("ZIP" in e for e in errors)


def test_validate_no_number_in_street() -> None:
    errors = validate_address("Main Street", "Atlanta", "GA", "30303")
    assert any("number" in e for e in errors)
