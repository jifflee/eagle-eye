"""Unit tests for 9 new tier-1 API connectors.

All tests use mocked HTTP responses — no network access required.
Tests cover: discover() happy path, error handling, cache hit/miss, entity creation.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import httpx
import pytest

# ---------------------------------------------------------------------------
# Connector modules — patch cache and HTTP at the usage site, not definition.
# When a connector does `from app.cache.redis_cache import get_cached`, the
# reference is bound in the connector module, so we must patch there.
# ---------------------------------------------------------------------------

MOD = {
    "fec": "app.connectors.tier1.openfec",
    "usa": "app.connectors.tier1.usaspending",
    "pp": "app.connectors.tier1.propublica_nonprofit",
    "fdic": "app.connectors.tier1.fdic_bankfind",
    "osm": "app.connectors.tier1.overpass_osm",
    "wb": "app.connectors.tier1.wayback",
    "fcc": "app.connectors.tier1.fcc_license",
    "uspto": "app.connectors.tier1.uspto_trademark",
    "gov": "app.connectors.tier1.govinfo",
}


@pytest.fixture(autouse=True)
def _no_cache():
    """Patch get_cached/set_cached at every connector module."""
    patches = []
    for mod in MOD.values():
        patches.append(patch(f"{mod}.get_cached", new_callable=AsyncMock, return_value=None))
        patches.append(patch(f"{mod}.set_cached", new_callable=AsyncMock))
    for p in patches:
        p.start()
    yield
    for p in patches:
        p.stop()


# =========================================================================
# 1. OpenFEC
# =========================================================================

class TestOpenFEC:
    M = MOD["fec"]

    @pytest.fixture
    def connector(self):
        from app.connectors.tier1.openfec import OpenFECConnector
        return OpenFECConnector()

    @pytest.mark.asyncio
    async def test_discover_person(self, connector):
        resp = {"results": [{"contributor_name": "DOE, JOHN", "contributor_employer": "ACME CORP", "contributor_occupation": "ENGINEER", "contributor_city": "ATLANTA", "contributor_state": "GA", "contributor_zip": "30301", "contribution_receipt_amount": 500.0, "contribution_receipt_date": "2024-01-15", "committee": {"name": "Friends of Democracy"}}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "PERSON", "full_name": "John Doe", "id": "p1"})
        assert not result.error
        assert len(result.entities) == 1
        assert result.entities[0]["type"] == "PERSON"
        assert result.entities[0]["employer"] == "ACME CORP"

    @pytest.mark.asyncio
    async def test_discover_address_needs_zip(self, connector):
        result = await connector.discover({"type": "ADDRESS"})
        assert result.error

    @pytest.mark.asyncio
    async def test_discover_address_creates_relationship(self, connector):
        resp = {"results": [{"contributor_name": "SMITH, JANE", "contributor_employer": "", "contributor_occupation": "", "contributor_city": "", "contributor_state": "", "contributor_zip": "30301", "contribution_receipt_amount": 100, "contribution_receipt_date": "2024-06-01", "committee": {"name": "PAC"}}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "ADDRESS", "zip": "30301", "id": "a1"})
        assert not result.error
        assert len(result.entities) == 1
        assert len(result.relationships) == 1
        assert result.relationships[0]["type"] == "LIVES_AT"

    @pytest.mark.asyncio
    async def test_discover_api_error(self, connector):
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, side_effect=httpx.ConnectError("timeout")):
            result = await connector.discover({"type": "PERSON", "full_name": "Test"})
        assert result.error

    @pytest.mark.asyncio
    async def test_cache_hit(self, connector):
        cached = {"entities": [{"id": "cached", "type": "PERSON"}], "relationships": []}
        with patch(f"{self.M}.get_cached", new_callable=AsyncMock, return_value=cached):
            result = await connector.discover({"type": "PERSON", "full_name": "Cached"})
        assert result.entities[0]["id"] == "cached"


# =========================================================================
# 2. USASpending
# =========================================================================

class TestUSASpending:
    M = MOD["usa"]

    @pytest.fixture
    def connector(self):
        from app.connectors.tier1.usaspending import USASpendingConnector
        return USASpendingConnector()

    @pytest.mark.asyncio
    async def test_discover_business(self, connector):
        resp = {"results": [{"Recipient Name": "ACME CORP", "Award ID": "AWD-001", "Award Amount": 1000000, "Awarding Agency": "DOD", "Award Type": "Contract", "Start Date": "2024-01-01"}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "BUSINESS", "name": "ACME CORP", "id": "b1"})
        assert not result.error
        assert len(result.entities) == 1
        assert result.entities[0]["type"] == "BUSINESS"
        assert result.entities[0]["federal_contractor"] is True

    @pytest.mark.asyncio
    async def test_discover_person_creates_relationship(self, connector):
        resp = {"results": [{"Recipient Name": "Doe Industries", "Award ID": "AWD-002", "Award Amount": 50000, "Awarding Agency": "HHS", "Award Type": "Grant", "Start Date": "2024-03-01"}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "PERSON", "full_name": "John Doe", "id": "p1"})
        assert not result.error
        assert len(result.relationships) == 1
        assert result.relationships[0]["type"] == "AFFILIATED_WITH"

    @pytest.mark.asyncio
    async def test_discover_short_name(self, connector):
        result = await connector.discover({"type": "BUSINESS", "name": "AB"})
        assert result.error

    @pytest.mark.asyncio
    async def test_discover_api_error(self, connector):
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, side_effect=Exception("500")):
            result = await connector.discover({"type": "BUSINESS", "name": "Test Corp"})
        assert result.error


# =========================================================================
# 3. ProPublica Nonprofit
# =========================================================================

class TestProPublicaNonprofit:
    M = MOD["pp"]

    @pytest.fixture
    def connector(self):
        from app.connectors.tier1.propublica_nonprofit import ProPublicaNonprofitConnector
        return ProPublicaNonprofitConnector()

    @pytest.mark.asyncio
    async def test_discover_address(self, connector):
        resp = {"organizations": [{"name": "Atlanta Food Bank", "ein": "123456789", "city": "Atlanta", "state": "GA", "ntee_code": "K31", "income_amount": 5000000, "asset_amount": 10000000}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "ADDRESS", "city": "Atlanta", "state": "GA", "id": "a1"})
        assert not result.error
        assert len(result.entities) == 1
        assert result.entities[0]["nonprofit"] is True
        assert result.entities[0]["ein"] == "123456789"

    @pytest.mark.asyncio
    async def test_discover_person(self, connector):
        resp = {"organizations": [{"name": "Doe Foundation", "ein": "987654321", "city": "Savannah", "state": "GA", "ntee_code": "A01", "income_amount": 100000, "asset_amount": 500000}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "PERSON", "full_name": "John Doe", "id": "p1"})
        assert not result.error
        assert len(result.entities) == 1

    @pytest.mark.asyncio
    async def test_discover_empty_results(self, connector):
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value={"organizations": []}):
            result = await connector.discover({"type": "BUSINESS", "name": "Nonexistent Org"})
        assert not result.error
        assert len(result.entities) == 0


# =========================================================================
# 4. FDIC BankFind
# =========================================================================

class TestFDICBankFind:
    M = MOD["fdic"]

    @pytest.fixture
    def connector(self):
        from app.connectors.tier1.fdic_bankfind import FDICBankFindConnector
        return FDICBankFindConnector()

    @pytest.mark.asyncio
    async def test_discover_address(self, connector):
        resp = {"data": [{"data": {"INSTNAME": "First National Bank", "OFFNAME": "Main Branch", "STADDR": "100 Main St", "CITY": "Atlanta", "STALP": "GA", "ZIP": "30301", "UNINUMBR": "12345", "MAINOFF": 1}}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "ADDRESS", "city": "Atlanta", "state": "GA"})
        assert not result.error
        assert len(result.entities) == 1
        assert result.entities[0]["type"] == "BUSINESS"
        assert result.entities[0]["name"] == "First National Bank"

    @pytest.mark.asyncio
    async def test_discover_needs_city_state(self, connector):
        result = await connector.discover({"type": "ADDRESS"})
        assert result.error

    @pytest.mark.asyncio
    async def test_discover_api_error(self, connector):
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, side_effect=Exception("API down")):
            result = await connector.discover({"type": "ADDRESS", "city": "Atlanta", "state": "GA"})
        assert result.error


# =========================================================================
# 5. Overpass OSM
# =========================================================================

class TestOverpassOSM:
    M = MOD["osm"]

    @pytest.fixture
    def connector(self):
        from app.connectors.tier1.overpass_osm import OverpassConnector
        return OverpassConnector()

    @pytest.mark.asyncio
    async def test_discover_address(self, connector):
        resp = {"elements": [{"type": "node", "id": 123456, "lat": 33.749, "lon": -84.388, "tags": {"name": "Local Coffee Shop", "amenity": "cafe", "addr:street": "Peachtree St", "phone": "+1-404-555-1234", "website": "https://localcoffee.com", "opening_hours": "Mo-Fr 07:00-19:00"}}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "ADDRESS", "latitude": 33.749, "longitude": -84.388})
        assert not result.error
        assert len(result.entities) == 1
        assert result.entities[0]["type"] == "BUSINESS"
        assert result.entities[0]["name"] == "Local Coffee Shop"

    @pytest.mark.asyncio
    async def test_discover_needs_coords(self, connector):
        result = await connector.discover({"type": "ADDRESS"})
        assert result.error

    @pytest.mark.asyncio
    async def test_discover_filters_unnamed(self, connector):
        resp = {"elements": [{"type": "node", "id": 1, "lat": 33.0, "lon": -84.0, "tags": {"amenity": "parking"}}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "ADDRESS", "latitude": 33.0, "longitude": -84.0})
        assert not result.error
        assert len(result.entities) == 0


# =========================================================================
# 6. Wayback Machine
# =========================================================================

class TestWayback:
    M = MOD["wb"]

    @pytest.fixture
    def connector(self):
        from app.connectors.tier1.wayback import WaybackConnector
        return WaybackConnector()

    @pytest.mark.asyncio
    async def test_discover_business(self, connector):
        resp = [["timestamp", "original", "statuscode", "mimetype"], ["20240115120000", "https://acme.com/", "200", "text/html"], ["20230601080000", "https://acme.com/about", "200", "text/html"]]
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "BUSINESS", "website": "acme.com"})
        assert not result.error
        assert len(result.entities) >= 1
        assert result.entities[0]["type"] == "SOCIAL_PROFILE"
        assert result.entities[0]["platform"] == "Wayback Machine"

    @pytest.mark.asyncio
    async def test_discover_no_website(self, connector):
        result = await connector.discover({"type": "BUSINESS"})
        assert result.error

    @pytest.mark.asyncio
    async def test_discover_empty_results(self, connector):
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=[]):
            result = await connector.discover({"type": "BUSINESS", "website": "nonexistent.example"})
        assert not result.error
        assert len(result.entities) == 0


# =========================================================================
# 7. FCC License
# =========================================================================

class TestFCCLicense:
    M = MOD["fcc"]

    @pytest.fixture
    def connector(self):
        from app.connectors.tier1.fcc_license import FCCLicenseConnector
        return FCCLicenseConnector()

    @pytest.mark.asyncio
    async def test_discover_person(self, connector):
        resp = {"Licenses": {"License": [{"licName": "DOE, JOHN", "licenseID": "FCC-001", "callsign": "W4ABC", "serviceDesc": "Amateur", "statusDesc": "Active", "expiredDate": "2030-01-01"}]}}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "PERSON", "full_name": "John Doe"})
        assert not result.error
        assert len(result.entities) == 1
        assert result.entities[0]["type"] == "BUSINESS"
        assert result.entities[0]["call_sign"] == "W4ABC"

    @pytest.mark.asyncio
    async def test_discover_single_license_dict(self, connector):
        resp = {"Licenses": {"License": {"licName": "ACME INC", "licenseID": "FCC-002", "callsign": "KABC", "serviceDesc": "Broadcast", "statusDesc": "Active", "expiredDate": "2028-06-15"}}}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "BUSINESS", "name": "ACME INC"})
        assert not result.error
        assert len(result.entities) == 1

    @pytest.mark.asyncio
    async def test_discover_short_name(self, connector):
        result = await connector.discover({"type": "PERSON", "full_name": "AB"})
        assert result.error


# =========================================================================
# 8. USPTO Trademark
# =========================================================================

class TestUSPTOTrademark:
    M = MOD["uspto"]

    @pytest.fixture
    def connector(self):
        from app.connectors.tier1.uspto_trademark import USPTOTrademarkConnector
        return USPTOTrademarkConnector()

    @pytest.mark.asyncio
    async def test_discover_person(self, connector):
        resp = {"response": {"docs": [{"inventionTitle": "Widget Machine", "applicantName": "Doe, John", "patentNumber": "US12345678", "applicationNumber": "APP-001", "filingDate": "2023-06-15"}]}}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "PERSON", "full_name": "John Doe"})
        assert not result.error
        assert len(result.entities) == 1
        assert result.entities[0]["type"] == "BUSINESS"
        assert result.entities[0]["patent_number"] == "US12345678"

    @pytest.mark.asyncio
    async def test_discover_business(self, connector):
        resp = {"response": {"docs": [{"inventionTitle": "Super Widget", "applicantName": "ACME Corp", "patentNumber": "US87654321", "applicationNumber": "APP-002", "filingDate": "2024-01-10"}]}}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "BUSINESS", "name": "ACME Corp"})
        assert not result.error
        assert len(result.entities) == 1

    @pytest.mark.asyncio
    async def test_discover_results_fallback(self, connector):
        resp = {"results": [{"inventionTitle": "Gadget", "applicantName": "Smith Inc", "patentNumber": "US111", "applicationNumber": "APP-003", "filingDate": "2024-02-01"}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "BUSINESS", "name": "Smith Inc"})
        assert not result.error
        assert len(result.entities) >= 1

    @pytest.mark.asyncio
    async def test_discover_short_name(self, connector):
        result = await connector.discover({"type": "PERSON", "full_name": "AB"})
        assert result.error


# =========================================================================
# 9. GovInfo
# =========================================================================

class TestGovInfo:
    M = MOD["gov"]

    @pytest.fixture
    def connector(self):
        from app.connectors.tier1.govinfo import GovInfoConnector
        return GovInfoConnector()

    @pytest.mark.asyncio
    async def test_discover_person(self, connector):
        resp = {"results": [{"packageId": "USCOURTS-gamd-1-23-cv-00123", "title": "Doe v. State of Georgia", "courtName": "U.S. District Court Middle District of Georgia", "publisher": "U.S. Courts", "dateIssued": "2024-03-15", "packageLink": "https://api.govinfo.gov/packages/USCOURTS-gamd-1-23-cv-00123"}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "PERSON", "full_name": "John Doe", "id": "p1"})
        assert not result.error
        assert len(result.entities) == 1
        assert result.entities[0]["type"] == "CASE"
        assert "Doe v. State" in result.entities[0]["case_name"]

    @pytest.mark.asyncio
    async def test_discover_creates_relationship(self, connector):
        resp = {"results": [{"packageId": "PKG-1", "title": "Corp v. Agency", "courtName": "Court", "publisher": "Courts", "dateIssued": "2024-01-01", "packageLink": "https://example.com"}]}
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, return_value=resp):
            result = await connector.discover({"type": "BUSINESS", "name": "Test Corp", "id": "b1"})
        assert not result.error
        assert len(result.relationships) == 1
        assert result.relationships[0]["type"] == "NAMED_IN_CASE"

    @pytest.mark.asyncio
    async def test_discover_short_name(self, connector):
        result = await connector.discover({"type": "PERSON", "full_name": "AB"})
        assert result.error

    @pytest.mark.asyncio
    async def test_discover_api_error(self, connector):
        with patch(f"{self.M}.fetch_json", new_callable=AsyncMock, side_effect=Exception("Service unavailable")):
            result = await connector.discover({"type": "PERSON", "full_name": "John Doe"})
        assert result.error
