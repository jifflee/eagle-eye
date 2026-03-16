#!/usr/bin/env python3
"""Load sample graph data into Neo4j for development and testing."""

import os
import sys

from neo4j import GraphDatabase

NEO4J_URI = os.getenv("NEO4J_URI", "bolt://localhost:7687")
NEO4J_USER = os.getenv("NEO4J_USER", "neo4j")
NEO4J_PASSWORD = os.getenv("NEO4J_PASSWORD", "eagle-eye-dev")


DEMO_CYPHER = """
// Create sample address
CREATE (addr:Address {
    id: 'addr-001',
    street: '123 Peachtree Lane',
    city: 'Lawrenceville',
    state: 'GA',
    zip: '30043',
    county: 'Gwinnett',
    latitude: 33.9562,
    longitude: -83.9880,
    address_type: 'residential'
})

// Create residents
CREATE (p1:Person {
    id: 'person-001',
    first_name: 'John',
    last_name: 'Smith',
    full_name: 'John Smith',
    gender: 'male'
})
CREATE (p2:Person {
    id: 'person-002',
    first_name: 'Jane',
    last_name: 'Smith',
    full_name: 'Jane Smith',
    gender: 'female'
})
CREATE (p3:Person {
    id: 'person-003',
    first_name: 'Robert',
    last_name: 'Johnson',
    full_name: 'Robert Johnson',
    gender: 'male'
})

// Create property
CREATE (prop:Property {
    id: 'prop-001',
    apn: 'R5001-123-456',
    assessed_value: 350000,
    market_value: 425000,
    year_built: 2005,
    square_footage: 2400,
    zoning_class: 'R-100',
    lot_size: 0.45
})

// Create business
CREATE (biz:Business {
    id: 'biz-001',
    name: 'Smith Consulting LLC',
    legal_name: 'Smith Consulting LLC',
    entity_type: 'LLC',
    status: 'active',
    formation_date: '2018-03-15'
})
CREATE (biz2:Business {
    id: 'biz-002',
    name: 'Peachtree Properties Inc',
    legal_name: 'Peachtree Properties Inc',
    entity_type: 'Corporation',
    status: 'active',
    formation_date: '2010-06-20'
})

// Create court case
CREATE (case1:Case {
    id: 'case-001',
    case_number: '2023-CV-12345',
    court_name: 'Gwinnett County Superior Court',
    court_type: 'county',
    case_type: 'civil',
    case_name: 'Johnson v. Smith Consulting LLC',
    filing_date: '2023-08-15',
    status: 'closed',
    disposition: 'dismissed'
})

// Create vehicle
CREATE (v1:Vehicle {
    id: 'vehicle-001',
    vin: '1HGCG5655WA123456',
    make: 'Honda',
    model: 'Accord',
    year: 2023,
    color: 'Silver'
})

// Create census tract
CREATE (ct:CensusTract {
    id: 'tract-001',
    tract_number: '0507.03',
    county: 'Gwinnett',
    state: 'GA',
    population: 5420,
    median_income: 78500,
    housing_units: 1890,
    owner_occupied_pct: 72.3
})

// Create environmental facility
CREATE (env:EnvironmentalFacility {
    id: 'env-001',
    facility_name: 'Gwinnett County Water Treatment',
    facility_type: 'Water Treatment',
    compliance_status: 'In Compliance',
    violations_count: 0
})

// Create social profiles
CREATE (social1:SocialProfile {
    id: 'social-001',
    platform: 'LinkedIn',
    username: 'johnsmith-consulting',
    profile_url: 'https://linkedin.com/in/johnsmith-consulting'
})

// Create phone & email
CREATE (phone1:PhoneNumber {
    id: 'phone-001',
    phone_number: '+17705551234',
    carrier: 'AT&T',
    line_type: 'mobile'
})
CREATE (email1:EmailAddress {
    id: 'email-001',
    email: 'john@smithconsulting.com',
    domain: 'smithconsulting.com',
    verified: true
})

// === Relationships ===

// People live at address
CREATE (p1)-[:LIVES_AT {from_date: '2015-06-01', verified: true, sources: ['qpublic']}]->(addr)
CREATE (p2)-[:LIVES_AT {from_date: '2015-06-01', verified: true, sources: ['qpublic']}]->(addr)

// People are related
CREATE (p1)-[:IS_RELATIVE_OF {relationship_type: 'spouse', confidence: 0.95, sources: ['public_records']}]->(p2)

// Property ownership
CREATE (p1)-[:OWNS_PROPERTY {ownership_pct: 50, sources: ['gsccca']}]->(prop)
CREATE (p2)-[:OWNS_PROPERTY {ownership_pct: 50, sources: ['gsccca']}]->(prop)

// Business ownership
CREATE (p1)-[:OWNS_BUSINESS {role: 'Managing Member', ownership_pct: 100, sources: ['ga_sos']}]->(biz)

// Neighbor relationship
CREATE (p3)-[:LIVES_AT {from_date: '2020-01-15', sources: ['qpublic']}]->(addr)

// Court case involvement
CREATE (p3)-[:NAMED_IN_CASE {party_type: 'plaintiff', sources: ['courtlistener']}]->(case1)
CREATE (biz)-[:NAMED_IN_CASE {party_type: 'defendant', sources: ['courtlistener']}]->(case1)

// Vehicle registration
CREATE (p1)-[:REGISTERED_VEHICLE {registration_date: '2023-01-10', sources: ['nhtsa']}]->(v1)

// Business location
CREATE (biz)-[:LOCATED_AT {office_type: 'headquarters', sources: ['ga_sos']}]->(addr)

// Address in census tract
CREATE (addr)-[:IN_CENSUS_TRACT {sources: ['census_geocoder']}]->(ct)

// Environmental facility nearby
CREATE (addr)-[:HAS_ENV_FACILITY {distance_meters: 2500, sources: ['epa_echo']}]->(env)

// Social profiles
CREATE (p1)-[:HAS_SOCIAL_PROFILE {sources: ['sherlock']}]->(social1)
CREATE (p1)-[:HAS_PHONE {primary: true, sources: ['public_records']}]->(phone1)
CREATE (p1)-[:HAS_EMAIL {primary: true, sources: ['hunter_io']}]->(email1)

// Business affiliated
CREATE (biz)-[:AFFILIATED_WITH {relationship_type: 'client', sources: ['sec_edgar']}]->(biz2)
"""


def main() -> None:
    print(f"Connecting to Neo4j at {NEO4J_URI}...")
    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASSWORD))

    try:
        driver.verify_connectivity()
        print("Connected successfully.")
    except Exception as e:
        print(f"Connection failed: {e}")
        sys.exit(1)

    with driver.session() as session:
        # Clear existing demo data
        print("Clearing existing data...")
        session.run("MATCH (n) DETACH DELETE n")

        # Load demo data
        print("Loading demo data...")
        session.run(DEMO_CYPHER)

        # Verify
        result = session.run("MATCH (n) RETURN labels(n) AS label, count(*) AS count")
        print("\nLoaded entities:")
        for record in result:
            print(f"  {record['label'][0]}: {record['count']}")

        result = session.run("MATCH ()-[r]->() RETURN type(r) AS type, count(*) AS count")
        print("\nLoaded relationships:")
        for record in result:
            print(f"  {record['type']}: {record['count']}")

    driver.close()
    print("\nDemo data loaded successfully!")


if __name__ == "__main__":
    main()
