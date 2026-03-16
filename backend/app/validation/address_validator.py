"""Address validation and normalization."""

from __future__ import annotations

import re

# Common abbreviation mappings
STREET_ABBREVIATIONS = {
    "st": "Street", "str": "Street",
    "ave": "Avenue", "av": "Avenue",
    "blvd": "Boulevard", "bvd": "Boulevard",
    "rd": "Road",
    "dr": "Drive",
    "ln": "Lane",
    "ct": "Court",
    "pl": "Place",
    "cir": "Circle",
    "pkwy": "Parkway", "pky": "Parkway",
    "hwy": "Highway",
    "trl": "Trail",
    "way": "Way",
    "ter": "Terrace",
    "pt": "Point",
    "xing": "Crossing",
    "sq": "Square",
    "aly": "Alley",
    "lp": "Loop",
}

DIRECTION_ABBREVIATIONS = {
    "n": "N", "s": "S", "e": "E", "w": "W",
    "ne": "NE", "nw": "NW", "se": "SE", "sw": "SW",
    "north": "N", "south": "S", "east": "E", "west": "W",
}

UNIT_TYPES = {"apt", "suite", "ste", "unit", "#", "bldg", "fl", "floor", "rm", "room"}

STATE_ABBREVIATIONS = {
    "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR",
    "california": "CA", "colorado": "CO", "connecticut": "CT", "delaware": "DE",
    "florida": "FL", "georgia": "GA", "hawaii": "HI", "idaho": "ID",
    "illinois": "IL", "indiana": "IN", "iowa": "IA", "kansas": "KS",
    "kentucky": "KY", "louisiana": "LA", "maine": "ME", "maryland": "MD",
    "massachusetts": "MA", "michigan": "MI", "minnesota": "MN", "mississippi": "MS",
    "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV",
    "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
    "north carolina": "NC", "north dakota": "ND", "ohio": "OH", "oklahoma": "OK",
    "oregon": "OR", "pennsylvania": "PA", "rhode island": "RI",
    "south carolina": "SC", "south dakota": "SD", "tennessee": "TN", "texas": "TX",
    "utah": "UT", "vermont": "VT", "virginia": "VA", "washington": "WA",
    "west virginia": "WV", "wisconsin": "WI", "wyoming": "WY",
    "district of columbia": "DC",
}

VALID_STATE_CODES = set(STATE_ABBREVIATIONS.values())


def normalize_address(
    street: str,
    city: str,
    state: str,
    zip_code: str,
) -> dict[str, str]:
    """Normalize an address to a standard format.

    Returns dict with normalized street, city, state, zip.
    """
    return {
        "street": normalize_street(street),
        "city": normalize_city(city),
        "state": normalize_state(state),
        "zip": normalize_zip(zip_code),
    }


def normalize_street(street: str) -> str:
    """Normalize a street address."""
    if not street:
        return ""

    # Clean up whitespace
    street = " ".join(street.split())

    # Split into words and process
    words = street.split()
    normalized = []

    for i, word in enumerate(words):
        lower = word.lower().rstrip(".,")

        # Check if it's a street type abbreviation (usually last or second-to-last)
        if lower in STREET_ABBREVIATIONS and i > 0:
            normalized.append(STREET_ABBREVIATIONS[lower])
        # Check if it's a direction
        elif lower in DIRECTION_ABBREVIATIONS:
            normalized.append(DIRECTION_ABBREVIATIONS[lower])
        # Capitalize normally
        else:
            # Keep numbers as-is, capitalize words
            if word[0].isdigit():
                normalized.append(word)
            else:
                normalized.append(word.capitalize())

    return " ".join(normalized)


def normalize_city(city: str) -> str:
    """Normalize a city name."""
    if not city:
        return ""
    return " ".join(word.capitalize() for word in city.split())


def normalize_state(state: str) -> str:
    """Normalize a state to 2-letter abbreviation."""
    if not state:
        return ""

    state = state.strip()

    # Already a 2-letter code
    if len(state) == 2:
        return state.upper()

    # Full state name
    lower = state.lower()
    if lower in STATE_ABBREVIATIONS:
        return STATE_ABBREVIATIONS[lower]

    return state.upper()[:2]


def normalize_zip(zip_code: str) -> str:
    """Normalize a ZIP code."""
    if not zip_code:
        return ""

    # Strip to digits and hyphens only
    cleaned = re.sub(r"[^\d-]", "", zip_code)

    # Ensure 5-digit or 5+4 format
    if len(cleaned) >= 5:
        return cleaned[:10]  # Allow ZIP+4

    return cleaned


def validate_address(
    street: str,
    city: str,
    state: str,
    zip_code: str,
) -> list[str]:
    """Validate an address, returning a list of error messages.

    Returns empty list if address is valid.
    """
    errors = []

    if not street or not street.strip():
        errors.append("Street address is required")
    elif not re.search(r"\d", street):
        errors.append("Street address should contain a number")

    if not city or not city.strip():
        errors.append("City is required")

    state_normalized = normalize_state(state)
    if not state_normalized:
        errors.append("State is required")
    elif state_normalized not in VALID_STATE_CODES:
        errors.append(f"Invalid state: {state}")

    if not zip_code or not zip_code.strip():
        errors.append("ZIP code is required")
    elif not re.match(r"^\d{5}(-\d{4})?$", zip_code.strip()):
        errors.append("ZIP code must be 5 digits (or 5+4 format)")

    return errors
