"""Tests for Pydantic entity models."""

from app.models.entities import (
    Address,
    Business,
    Case,
    CensusTract,
    CrimeRecord,
    EmailAddress,
    EntityType,
    EnvironmentalFacility,
    Person,
    PhoneNumber,
    Property,
    SocialProfile,
    Vehicle,
)
from app.models.relationships import Relationship, RelationshipProperties, RelationshipType
from app.models.schemas import AddressInput, InvestigationRequest, SearchRequest


def test_person_model() -> None:
    p = Person(first_name="John", last_name="Doe")
    assert p.entity_type == EntityType.PERSON
    assert p.full_name == "John Doe"
    assert p.id is not None


def test_person_with_middle_name() -> None:
    p = Person(first_name="John", middle_name="Michael", last_name="Doe")
    assert p.full_name == "John Michael Doe"


def test_address_model() -> None:
    a = Address(street="123 Main St", city="Atlanta", state="GA", zip="30303")
    assert a.entity_type == EntityType.ADDRESS
    assert a.country == "US"


def test_property_model() -> None:
    p = Property(apn="R5001-123", assessed_value=350000, year_built=2005)
    assert p.entity_type == EntityType.PROPERTY


def test_business_model() -> None:
    b = Business(name="Acme Inc", entity_type_business="LLC", status="active")
    assert b.entity_type == EntityType.BUSINESS


def test_case_model() -> None:
    c = Case(case_number="2023-CV-12345", court_type="county", case_type="civil")
    assert c.entity_type == EntityType.CASE


def test_vehicle_model() -> None:
    v = Vehicle(vin="1HGCG5655WA123456", make="Honda", model="Accord", year=2023)
    assert v.entity_type == EntityType.VEHICLE


def test_crime_record_model() -> None:
    cr = CrimeRecord(incident_type="burglary", jurisdiction="Gwinnett County")
    assert cr.entity_type == EntityType.CRIME_RECORD


def test_social_profile_model() -> None:
    sp = SocialProfile(platform="LinkedIn", username="johndoe")
    assert sp.entity_type == EntityType.SOCIAL_PROFILE


def test_phone_number_model() -> None:
    pn = PhoneNumber(phone_number="+17705551234", carrier="AT&T", line_type="mobile")
    assert pn.entity_type == EntityType.PHONE_NUMBER


def test_email_address_model() -> None:
    ea = EmailAddress(email="john@example.com", domain="example.com")
    assert ea.entity_type == EntityType.EMAIL_ADDRESS


def test_environmental_facility_model() -> None:
    ef = EnvironmentalFacility(facility_name="Water Treatment Plant", violations_count=3)
    assert ef.entity_type == EntityType.ENVIRONMENTAL_FACILITY


def test_census_tract_model() -> None:
    ct = CensusTract(
        tract_number="0507.03", county="Gwinnett", state="GA",
        population=5420, median_income=78500,
    )
    assert ct.entity_type == EntityType.CENSUS_TRACT


def test_relationship_model() -> None:
    from uuid import uuid4

    r = Relationship(
        source_id=uuid4(),
        target_id=uuid4(),
        relationship_type=RelationshipType.LIVES_AT,
        properties=RelationshipProperties(
            confidence=0.95,
            verified=True,
            sources=["qpublic"],
        ),
    )
    assert r.relationship_type == RelationshipType.LIVES_AT
    assert r.properties.confidence == 0.95


def test_all_entity_types_covered() -> None:
    assert len(EntityType) == 12


def test_all_relationship_types_covered() -> None:
    assert len(RelationshipType) == 15


def test_address_input_validation() -> None:
    addr = AddressInput(street="123 Main St", city="Atlanta", state="GA", zip="30303")
    assert addr.state == "GA"


def test_investigation_request() -> None:
    req = InvestigationRequest(
        address=AddressInput(street="123 Main", city="Atlanta", state="GA", zip="30303")
    )
    assert req.enrichment_config is None


def test_search_request() -> None:
    req = SearchRequest(query="john doe", limit=20)
    assert req.entity_types is None
    assert req.offset == 0
