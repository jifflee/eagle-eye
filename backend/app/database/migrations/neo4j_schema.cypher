// Eagle Eye — Neo4j Schema Initialization
// Run once on fresh database to create constraints and indexes

// === Uniqueness Constraints (also create indexes) ===

CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE;
CREATE CONSTRAINT address_id IF NOT EXISTS FOR (a:Address) REQUIRE a.id IS UNIQUE;
CREATE CONSTRAINT property_id IF NOT EXISTS FOR (p:Property) REQUIRE p.id IS UNIQUE;
CREATE CONSTRAINT business_id IF NOT EXISTS FOR (b:Business) REQUIRE b.id IS UNIQUE;
CREATE CONSTRAINT case_id IF NOT EXISTS FOR (c:Case) REQUIRE c.id IS UNIQUE;
CREATE CONSTRAINT vehicle_id IF NOT EXISTS FOR (v:Vehicle) REQUIRE v.id IS UNIQUE;
CREATE CONSTRAINT crime_record_id IF NOT EXISTS FOR (cr:CrimeRecord) REQUIRE cr.id IS UNIQUE;
CREATE CONSTRAINT social_profile_id IF NOT EXISTS FOR (sp:SocialProfile) REQUIRE sp.id IS UNIQUE;
CREATE CONSTRAINT phone_number_id IF NOT EXISTS FOR (pn:PhoneNumber) REQUIRE pn.id IS UNIQUE;
CREATE CONSTRAINT email_address_id IF NOT EXISTS FOR (ea:EmailAddress) REQUIRE ea.id IS UNIQUE;
CREATE CONSTRAINT env_facility_id IF NOT EXISTS FOR (ef:EnvironmentalFacility) REQUIRE ef.id IS UNIQUE;
CREATE CONSTRAINT census_tract_id IF NOT EXISTS FOR (ct:CensusTract) REQUIRE ct.id IS UNIQUE;

// === Property Indexes for Common Lookups ===

CREATE INDEX person_name IF NOT EXISTS FOR (p:Person) ON (p.last_name, p.first_name);
CREATE INDEX address_street IF NOT EXISTS FOR (a:Address) ON (a.street, a.city, a.state, a.zip);
CREATE INDEX address_coords IF NOT EXISTS FOR (a:Address) ON (a.latitude, a.longitude);
CREATE INDEX business_name IF NOT EXISTS FOR (b:Business) ON (b.name);
CREATE INDEX case_number IF NOT EXISTS FOR (c:Case) ON (c.case_number);
CREATE INDEX property_apn IF NOT EXISTS FOR (p:Property) ON (p.apn);
CREATE INDEX vehicle_vin IF NOT EXISTS FOR (v:Vehicle) ON (v.vin);
CREATE INDEX census_tract_number IF NOT EXISTS FOR (ct:CensusTract) ON (ct.tract_number, ct.county, ct.state);

// === Full-Text Search Indexes ===

CREATE FULLTEXT INDEX person_fulltext IF NOT EXISTS
FOR (p:Person)
ON EACH [p.first_name, p.last_name, p.full_name];

CREATE FULLTEXT INDEX business_fulltext IF NOT EXISTS
FOR (b:Business)
ON EACH [b.name, b.legal_name];

CREATE FULLTEXT INDEX address_fulltext IF NOT EXISTS
FOR (a:Address)
ON EACH [a.street, a.city];

CREATE FULLTEXT INDEX case_fulltext IF NOT EXISTS
FOR (c:Case)
ON EACH [c.case_number, c.case_name];
