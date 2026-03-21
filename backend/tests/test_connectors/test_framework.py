"""Tests for the connector framework, registry, rate limiter, and cache."""

import asyncio

from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.connectors.registry import (
    discover_connectors,
    get_connector,
    get_connectors_by_tier,
    reset_registry,
)
from app.models.entities import EntityType
from app.rate_limiting.limiter import CircuitBreaker, RateLimiter, TokenBucket


def test_connector_registry_discovers_all() -> None:
    reset_registry()
    connectors = discover_connectors()
    # Active connectors: 18 tier1 + 2 active tier2 + 1 tier3 = 21
    # 5 disabled connectors live in _disabled/ and are NOT discovered.
    assert len(connectors) >= 12
    tier1 = [
        "census_geocoder", "census_data", "fbi_crime",
        "epa_echo", "sec_edgar", "courtlistener",
        "openfema", "nominatim", "nhtsa_vpic",
    ]
    tier2_active = [
        "gwinnett_parcel", "ga_secretary_state",
    ]
    disabled_should_be_absent = [
        "qpublic", "gsccca_deeds", "gbi_sex_offender",
        "gwinnett_sheriff_jail", "gwinnett_courts",
    ]
    for name in tier1 + tier2_active:
        assert name in connectors, f"Missing connector: {name}"
    for name in disabled_should_be_absent:
        assert name not in connectors, f"Disabled connector should not be registered: {name}"


def test_get_connector_by_name() -> None:
    reset_registry()
    discover_connectors()
    connector = get_connector("census_geocoder")
    assert connector is not None
    assert connector.name == "census_geocoder"
    assert connector.tier == 1
    assert connector.requires_auth is False


def test_get_connectors_by_tier() -> None:
    reset_registry()
    discover_connectors()
    tier1 = get_connectors_by_tier(1)
    assert len(tier1) >= 3
    for c in tier1:
        assert c.tier == 1


def test_connector_supported_types() -> None:
    reset_registry()
    discover_connectors()
    geocoder = get_connector("census_geocoder")
    assert geocoder is not None
    assert geocoder.can_discover_from(EntityType.ADDRESS)
    assert not geocoder.can_discover_from(EntityType.PERSON)
    assert geocoder.can_produce(EntityType.CENSUS_TRACT)


def test_token_bucket() -> None:
    bucket = TokenBucket(rate=10.0, max_tokens=5.0)
    assert bucket.tokens == 5.0

    # Consume tokens
    loop = asyncio.new_event_loop()
    result = loop.run_until_complete(bucket.acquire(timeout=1.0))
    assert result is True
    loop.close()


def test_circuit_breaker_closed() -> None:
    cb = CircuitBreaker(failure_threshold=3)
    assert cb.state == "closed"
    assert cb.is_available()


def test_circuit_breaker_opens_after_failures() -> None:
    cb = CircuitBreaker(failure_threshold=3)
    cb.record_failure()
    cb.record_failure()
    assert cb.is_available()
    cb.record_failure()
    assert cb.state == "open"
    assert not cb.is_available()


def test_circuit_breaker_resets_on_success() -> None:
    cb = CircuitBreaker(failure_threshold=3)
    cb.record_failure()
    cb.record_failure()
    cb.record_success()
    assert cb.state == "closed"
    assert cb.failure_count == 0


def test_rate_limiter() -> None:
    rl = RateLimiter()
    rl.configure("test_connector", requests_per_second=10.0, burst_size=5)

    # Should be available
    assert rl.is_available("test_connector")

    status = rl.get_status("test_connector")
    assert status["circuit_breaker"] == "closed"


def test_rate_limiter_circuit_breaker() -> None:
    rl = RateLimiter()
    rl.configure("failing_connector", failure_threshold=2)

    rl.record_failure("failing_connector")
    rl.record_failure("failing_connector")
    assert not rl.is_available("failing_connector")


def test_connector_result() -> None:
    result = ConnectorResult(
        entities=[{"id": "1", "type": "PERSON"}],
        relationships=[],
        source_name="test",
        confidence=0.9,
    )
    assert len(result.entities) == 1
    assert result.confidence == 0.9
    assert result.error is None
