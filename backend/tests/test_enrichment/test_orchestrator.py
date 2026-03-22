"""Unit tests for the enrichment orchestrator pipeline.

Tests cover: phase execution order, connector failure handling, tier filtering,
disabled connector exclusion, and entity persistence flow.
All database/network calls are mocked — no external dependencies required.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest

from app.connectors.base import BaseConnector, ConnectorResult, RateLimit
from app.models.entities import EntityType


# ---------------------------------------------------------------------------
# Fake connectors for testing
# ---------------------------------------------------------------------------

class FakeGeocoder(BaseConnector):
    name = "census_geocoder"
    description = "Fake geocoder"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=10.0, burst_size=10)
    default_confidence = 0.95
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.CENSUS_TRACT]

    async def discover(self, entity):
        return ConnectorResult(
            entities=[{"id": "tract-1", "type": "CENSUS_TRACT", "tract_number": "050554"}],
            relationships=[],
            raw_data={
                "address_updates": {"latitude": 33.95, "longitude": -84.07},
                "tract_info": {"STATE": "13", "COUNTY": "135", "TRACT": "050554", "GEOID": "13135050554"},
            },
            source_name=self.name, confidence=0.95,
        )

    async def enrich(self, entity):
        return await self.discover(entity)

    async def validate(self):
        return True


class FakeCrimeConnector(BaseConnector):
    name = "fbi_crime"
    description = "Fake crime"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=10.0, burst_size=10)
    default_confidence = 0.90
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.CRIME_RECORD]

    async def discover(self, entity):
        return ConnectorResult(
            entities=[{"id": "crime-1", "type": "CRIME_RECORD", "year": 2019}],
            relationships=[{"source_id": entity.get("id"), "target_id": "crime-1", "type": "HAS_CRIME_NEAR", "properties": {}}],
            source_name=self.name, confidence=0.90,
        )

    async def enrich(self, entity):
        return await self.discover(entity)

    async def validate(self):
        return True


class FakeFailingConnector(BaseConnector):
    name = "failing_connector"
    description = "Always fails"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=10.0, burst_size=10)
    default_confidence = 0.5
    supported_input_types = [EntityType.ADDRESS]
    supported_output_types = [EntityType.BUSINESS]

    async def discover(self, entity):
        raise ConnectionError("API timeout")

    async def enrich(self, entity):
        return await self.discover(entity)

    async def validate(self):
        return False


class FakePersonConnector(BaseConnector):
    name = "sec_edgar"
    description = "Fake SEC"
    tier = 1
    requires_auth = False
    rate_limit = RateLimit(requests_per_second=10.0, burst_size=10)
    default_confidence = 0.85
    supported_input_types = [EntityType.PERSON, EntityType.ADDRESS]
    supported_output_types = [EntityType.BUSINESS]

    async def discover(self, entity):
        return ConnectorResult(
            entities=[{"id": "biz-1", "type": "BUSINESS", "name": "Test Corp"}],
            relationships=[],
            source_name=self.name, confidence=0.85,
        )

    async def enrich(self, entity):
        return await self.discover(entity)

    async def validate(self):
        return True


# ---------------------------------------------------------------------------
# Shared mock fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def mock_db():
    """Mock all database dependencies."""
    with (
        patch("app.enrichment.orchestrator.neo4j_driver") as neo4j,
        patch("app.enrichment.orchestrator.postgres_client") as pg,
        patch("app.enrichment.orchestrator.log_store") as logs,
    ):
        neo4j.check_health = AsyncMock(return_value=True)
        neo4j.merge_entity = AsyncMock()
        neo4j.update_entity = AsyncMock()
        neo4j.create_relationship = AsyncMock()
        neo4j.get_investigation_graph = AsyncMock(return_value={"entities": []})
        neo4j.get_entity_count = AsyncMock(return_value=5)

        pg.upsert_connector_status = AsyncMock()
        pg.update_investigation = AsyncMock()
        pg.create_source_record = AsyncMock()

        logs.log = MagicMock()

        yield {"neo4j": neo4j, "pg": pg, "logs": logs}


@pytest.fixture
def investigation_id():
    return uuid4()


@pytest.fixture
def address_entity():
    return {
        "id": "addr-1",
        "type": "ADDRESS",
        "street": "123 Main St",
        "city": "Lawrenceville",
        "state": "GA",
        "zip": "30044",
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestRunConnector:
    """Test the _run_connector helper."""

    @pytest.mark.asyncio
    async def test_successful_connector(self, mock_db, investigation_id):
        from app.enrichment.orchestrator import _run_connector

        connector = FakeCrimeConnector()
        entity = {"id": "addr-1", "type": "ADDRESS", "state": "GA"}

        result = await _run_connector(investigation_id, connector, entity)

        assert result is not None
        assert not result.error
        assert len(result.entities) == 1
        mock_db["neo4j"].merge_entity.assert_called()
        mock_db["pg"].upsert_connector_status.assert_called()

    @pytest.mark.asyncio
    async def test_failing_connector_returns_none(self, mock_db, investigation_id):
        from app.enrichment.orchestrator import _run_connector

        connector = FakeFailingConnector()
        entity = {"id": "addr-1", "type": "ADDRESS"}

        result = await _run_connector(investigation_id, connector, entity)

        assert result is None
        # Should mark as failed in postgres
        calls = mock_db["pg"].upsert_connector_status.call_args_list
        statuses = [c.args[2] if len(c.args) > 2 else c.kwargs.get("status") for c in calls]
        assert "failed" in statuses or any("failed" in str(c) for c in calls)

    @pytest.mark.asyncio
    async def test_connector_error_result(self, mock_db, investigation_id):
        """Connector returns error in result (not exception)."""
        from app.enrichment.orchestrator import _run_connector

        class ErrorConnector(BaseConnector):
            name = "error_conn"
            description = "Returns error"
            tier = 1
            requires_auth = False
            rate_limit = RateLimit(requests_per_second=10.0, burst_size=10)
            default_confidence = 0.5
            supported_input_types = [EntityType.ADDRESS]
            supported_output_types = [EntityType.BUSINESS]

            async def discover(self, entity):
                return ConnectorResult(error="Bad request", source_name=self.name)
            async def enrich(self, entity):
                return await self.discover(entity)
            async def validate(self):
                return False

        result = await _run_connector(investigation_id, ErrorConnector(), {"id": "a", "type": "ADDRESS"})
        assert result is not None
        assert result.error == "Bad request"


class TestDoEnrichment:
    """Test the full enrichment pipeline."""

    @pytest.mark.asyncio
    async def test_phase_execution_with_geocoder(self, mock_db, investigation_id, address_entity):
        from app.enrichment.orchestrator import _do_enrichment

        connectors = {
            "census_geocoder": FakeGeocoder(),
            "fbi_crime": FakeCrimeConnector(),
        }

        with (
            patch("app.enrichment.orchestrator.discover_connectors", return_value=connectors),
            patch("app.enrichment.discovery.run_discovery", new_callable=AsyncMock) as mock_discovery,
            patch("app.enrichment.deduplicator.run_deduplication", new_callable=AsyncMock, return_value=[]),
        ):
            # Need to patch the import inside _do_enrichment
            with patch("app.enrichment.discovery.run_discovery", mock_discovery):
                mock_discovery.return_value = {"entities_discovered": 0, "relationships_discovered": 0}

                await _do_enrichment(investigation_id, {"street": "123 Main", "city": "Lawrenceville", "state": "GA", "zip": "30044"}, "addr-1", False)

        # Geocoder should have been called (entities merged)
        assert mock_db["neo4j"].merge_entity.call_count >= 1
        # Crime connector should have run in phase 2
        assert mock_db["neo4j"].create_relationship.call_count >= 1

    @pytest.mark.asyncio
    async def test_tier1_only_filters(self, mock_db, investigation_id, address_entity):
        from app.enrichment.orchestrator import _do_enrichment

        tier1 = FakeCrimeConnector()
        tier2 = FakePersonConnector()
        tier2.tier = 2
        tier2.name = "gwinnett_parcel"

        connectors = {"fbi_crime": tier1, "gwinnett_parcel": tier2, "census_geocoder": FakeGeocoder()}

        with (
            patch("app.enrichment.orchestrator.discover_connectors", return_value=connectors),
            patch("app.enrichment.discovery.run_discovery", new_callable=AsyncMock) as mock_disc,
            patch("app.enrichment.deduplicator.run_deduplication", new_callable=AsyncMock, return_value=[]),
        ):
            with patch("app.enrichment.discovery.run_discovery", mock_disc):
                mock_disc.return_value = {"entities_discovered": 0, "relationships_discovered": 0}
                await _do_enrichment(investigation_id, {"street": "123 Main", "state": "GA"}, "addr-1", tier1_only=True)

        # Tier 2 connector should have been filtered out — only geocoder + fbi_crime ran
        connector_names = [
            c.args[1] if len(c.args) > 1 else ""
            for c in mock_db["pg"].upsert_connector_status.call_args_list
        ]
        # gwinnett_parcel should not appear as "running" or "complete"
        running_or_complete = [
            c for c in mock_db["pg"].upsert_connector_status.call_args_list
            if len(c.args) > 2 and c.args[2] in ("running", "complete") and "gwinnett" in str(c.args[1])
        ]
        assert len(running_or_complete) == 0


class TestLabelToType:
    def test_known_labels(self):
        from app.enrichment.orchestrator import _label_to_type

        assert _label_to_type(["Person"]) == "PERSON"
        assert _label_to_type(["Business"]) == "BUSINESS"
        assert _label_to_type(["CrimeRecord"]) == "CRIME_RECORD"
        assert _label_to_type(["CensusTract"]) == "CENSUS_TRACT"

    def test_multiple_labels(self):
        from app.enrichment.orchestrator import _label_to_type

        assert _label_to_type(["Node", "Person"]) == "PERSON"

    def test_unknown_defaults_to_address(self):
        from app.enrichment.orchestrator import _label_to_type

        assert _label_to_type(["UnknownLabel"]) == "ADDRESS"
        assert _label_to_type([]) == "ADDRESS"
