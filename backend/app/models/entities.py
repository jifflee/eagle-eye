"""Entity models for all 12 OSINT entity types."""

from __future__ import annotations

import enum
from datetime import date, datetime
from uuid import UUID, uuid4

from pydantic import BaseModel, Field


class EntityType(str, enum.Enum):
    PERSON = "PERSON"
    ADDRESS = "ADDRESS"
    PROPERTY = "PROPERTY"
    BUSINESS = "BUSINESS"
    CASE = "CASE"
    VEHICLE = "VEHICLE"
    CRIME_RECORD = "CRIME_RECORD"
    SOCIAL_PROFILE = "SOCIAL_PROFILE"
    PHONE_NUMBER = "PHONE_NUMBER"
    EMAIL_ADDRESS = "EMAIL_ADDRESS"
    ENVIRONMENTAL_FACILITY = "ENVIRONMENTAL_FACILITY"
    CENSUS_TRACT = "CENSUS_TRACT"


class BaseEntity(BaseModel):
    id: UUID = Field(default_factory=uuid4)
    entity_type: EntityType
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


class Person(BaseEntity):
    entity_type: EntityType = EntityType.PERSON
    first_name: str
    middle_name: str | None = None
    last_name: str
    full_name: str | None = None
    aliases: list[str] = Field(default_factory=list)
    date_of_birth: date | None = None
    gender: str | None = None

    def model_post_init(self, __context: object) -> None:
        if not self.full_name:
            parts = [self.first_name]
            if self.middle_name:
                parts.append(self.middle_name)
            parts.append(self.last_name)
            self.full_name = " ".join(parts)


class Address(BaseEntity):
    entity_type: EntityType = EntityType.ADDRESS
    street: str
    city: str
    state: str
    zip: str
    county: str | None = None
    country: str = "US"
    latitude: float | None = None
    longitude: float | None = None
    address_type: str | None = None  # residential, commercial, unknown
    property_type: str | None = None  # house, apartment, business


class Property(BaseEntity):
    entity_type: EntityType = EntityType.PROPERTY
    address_id: UUID | None = None
    apn: str | None = None  # Assessor Parcel Number
    owner_name: str | None = None
    owner_type: str | None = None  # individual, business
    assessed_value: float | None = None
    market_value: float | None = None
    zoning_class: str | None = None
    square_footage: int | None = None
    lot_size: float | None = None  # acres
    year_built: int | None = None
    bedrooms: int | None = None
    bathrooms: float | None = None
    sale_history: list[SaleRecord] = Field(default_factory=list)


class SaleRecord(BaseModel):
    sale_date: date | None = None
    sale_price: float | None = None
    buyer: str | None = None
    seller: str | None = None
    deed_type: str | None = None
    book_page: str | None = None


class Business(BaseEntity):
    entity_type: EntityType = EntityType.BUSINESS
    name: str
    legal_name: str | None = None
    aliases: list[str] = Field(default_factory=list)
    entity_type_business: str | None = None  # LLC, C-Corp, S-Corp, Partnership
    status: str | None = None  # active, inactive, dissolved
    formation_date: date | None = None
    dissolution_date: date | None = None
    registered_agent: str | None = None
    principal_address_id: UUID | None = None
    naics_code: str | None = None
    sic_code: str | None = None
    officers: list[str] = Field(default_factory=list)


class Case(BaseEntity):
    entity_type: EntityType = EntityType.CASE
    case_number: str
    court_name: str | None = None
    court_type: str | None = None  # federal, state, county
    case_name: str | None = None
    case_type: str | None = None  # civil, criminal, probate, traffic
    filing_date: date | None = None
    disposition_date: date | None = None
    disposition: str | None = None
    status: str | None = None
    charges: list[str] = Field(default_factory=list)
    judgement_amount: float | None = None
    docket_url: str | None = None


class Vehicle(BaseEntity):
    entity_type: EntityType = EntityType.VEHICLE
    vin: str | None = None
    license_plate: str | None = None
    make: str | None = None
    model: str | None = None
    year: int | None = None
    color: str | None = None
    body_type: str | None = None
    vehicle_class: str | None = None


class CrimeRecord(BaseEntity):
    entity_type: EntityType = EntityType.CRIME_RECORD
    incident_type: str
    incident_date: date | None = None
    jurisdiction: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    description: str | None = None
    source_case_number: str | None = None


class SocialProfile(BaseEntity):
    entity_type: EntityType = EntityType.SOCIAL_PROFILE
    platform: str
    username: str
    profile_url: str | None = None
    follower_count: int | None = None
    is_public: bool | None = None
    is_verified: bool | None = None


class PhoneNumber(BaseEntity):
    entity_type: EntityType = EntityType.PHONE_NUMBER
    phone_number: str
    country_code: str = "1"
    carrier: str | None = None
    line_type: str | None = None  # mobile, landline, VoIP


class EmailAddress(BaseEntity):
    entity_type: EntityType = EntityType.EMAIL_ADDRESS
    email: str
    domain: str | None = None
    breach_count: int = 0
    verified: bool | None = None


class EnvironmentalFacility(BaseEntity):
    entity_type: EntityType = EntityType.ENVIRONMENTAL_FACILITY
    facility_name: str
    facility_type: str | None = None
    agency: str | None = None  # EPA, state, county
    regulatory_status: str | None = None
    compliance_status: str | None = None
    violations_count: int = 0
    penalties_total: float | None = None


class CensusTract(BaseEntity):
    entity_type: EntityType = EntityType.CENSUS_TRACT
    tract_number: str
    block_number: str | None = None
    county: str | None = None
    state: str | None = None
    population: int | None = None
    median_income: float | None = None
    housing_units: int | None = None
    owner_occupied_pct: float | None = None
    poverty_rate: float | None = None
    unemployment_rate: float | None = None


# Type alias for any entity
AnyEntity = (
    Person
    | Address
    | Property
    | Business
    | Case
    | Vehicle
    | CrimeRecord
    | SocialProfile
    | PhoneNumber
    | EmailAddress
    | EnvironmentalFacility
    | CensusTract
)

# Map entity type enum to model class
ENTITY_TYPE_MAP: dict[EntityType, type[BaseEntity]] = {
    EntityType.PERSON: Person,
    EntityType.ADDRESS: Address,
    EntityType.PROPERTY: Property,
    EntityType.BUSINESS: Business,
    EntityType.CASE: Case,
    EntityType.VEHICLE: Vehicle,
    EntityType.CRIME_RECORD: CrimeRecord,
    EntityType.SOCIAL_PROFILE: SocialProfile,
    EntityType.PHONE_NUMBER: PhoneNumber,
    EntityType.EMAIL_ADDRESS: EmailAddress,
    EntityType.ENVIRONMENTAL_FACILITY: EnvironmentalFacility,
    EntityType.CENSUS_TRACT: CensusTract,
}
