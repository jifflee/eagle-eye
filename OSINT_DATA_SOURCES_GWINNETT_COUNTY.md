# OSINT Data Sources: Gwinnett County, Georgia

Comprehensive inventory of publicly available data sources for Gwinnett County, GA, with focus on programmatic access.

---

## 1. Property / Tax Records

### Gwinnett County Tax Assessor - Property Ownership Database
- **URL:** https://www.gwinnettcounty.com/departments/financialservices/taxassessorsoffice/property-ownership-database
- **Access Method:** Downloadable ZIP file (updated quarterly); web search via portal
- **Data Fields:** Owner name, parcel ID, property address, assessed value, land value, improvement value, acreage, property class, tax district
- **API:** No formal API. Data files available for bulk download.
- **Restrictions:** Public data under Georgia Open Records Act. No authentication required for downloads.

### qPublic (Schneider Corp) - Gwinnett County
- **URL:** https://qpublic.schneidercorp.com/Application.aspx?AppID=1282&LayerID=43872&PageTypeID=1&PageID=16057
- **Access Method:** Web portal with map and search interface. Scraping possible but no official API.
- **Data Fields:** Owner name, parcel ID, legal description, property address, sale history, assessed/appraised values, tax amounts, building characteristics (sq ft, bedrooms, bathrooms, year built), land use codes
- **API:** None. Web scraping required (Schneider Corp ToS may restrict automated access).
- **Rate Limits:** Unknown; standard anti-bot protections likely in place.

### Gwinnett County Tax Commissioner
- **URL:** https://www.gwinnetttaxcommissioner.com/property-tax
- **Access Method:** Web portal for tax bill lookup and payment status
- **Data Fields:** Tax bill amounts, payment status, millage rates, exemptions
- **API:** None.

### GSCCCA - Real Estate Deed Records (Statewide)
- **URL:** https://search.gsccca.org/RealEstate/
- **Access Method:** Web search portal. Subscription may be required for full access.
- **Data Fields:** Grantor/grantee names, instrument type (deed, mortgage, lien), book/page, recording date, document images
- **API:** GSCCCA references web-based APIs (TLS 1.2 required). Contact GSCCCA for developer access details.
- **Restrictions:** Some features require paid subscription. Free access available at clerk of court offices.

### Gwinnett County Clerk of Court - Deeds and Land Records
- **URL:** https://www.gwinnettcourts.com/deeds-and-land-records/
- **Access Method:** In-person or via GSCCCA online portal
- **Data Fields:** Deeds, liens, plats, easements, lis pendens

---

## 2. Court / Legal Records

### Gwinnett Courts - Case Search
- **URL:** https://www.gwinnettcourts.com/casesearch/
- **Access Method:** Web search by name, case number, or citation number
- **Data Fields:** Case number, parties, case type (civil, criminal, traffic), filing date, case status, charges, disposition
- **API:** None. Scraping required. Standard web form interface.

### Gwinnett County eCourt Public Portal
- **URL:** https://portal-gwinnett.ecourt.com/public-portal/
- **Access Method:** Web portal with search functionality
- **Data Fields:** Case index, hearing dates, case status, party information
- **API:** None documented publicly.

### re:SearchGA (Tyler Technologies / Odyssey)
- **URL:** http://researchga.tylerhost.net/
- **Access Method:** Web portal. Searchable across 18+ counties including Gwinnett.
- **Data Fields:** Case index, filed documents, keywords within documents, case history. Over 4 million cases indexed.
- **API:** None public. Tyler Technologies may offer enterprise API access.
- **Note:** Provides unofficial copies. Clerk of court is official custodian.

### Georgia E-Access to Court Records
- **URL:** https://georgiacourts.gov/eaccess-court-records/
- **Access Method:** Directory of county-level court record portals
- **Data Fields:** Varies by county system

### PACER - Northern District of Georgia (Federal)
- **URL:** https://ecf.gand.uscourts.gov/
- **PACER Lookup:** https://pacer.uscourts.gov/
- **Access Method:** Requires PACER account registration (free). Per-page fees ($0.10/page, capped at $3.00/document).
- **Data Fields:** Federal civil/criminal case dockets, filings, party information, judge assignments, document PDFs
- **API:** PACER has a Case Locator search API. Third-party APIs available (see below).
- **Rate Limits:** No formal rate limit but excessive automated access may trigger account review.

### CourtListener / RECAP (Free Law Project)
- **URL:** https://www.courtlistener.com/recap/
- **API:** https://www.courtlistener.com/help/api/rest/
- **Access Method:** Free REST API. No authentication needed for search. Covers federal courts including N.D. Georgia.
- **Data Fields:** Dockets, filings, opinions, oral arguments. Millions of PACER documents mirrored for free.
- **Rate Limits:** Reasonable use policy. Bulk data downloads available.

### UniCourt - PACER API
- **URL:** https://unicourt.com/
- **Access Method:** Commercial API. Real-time access to full PACER database.
- **Data Fields:** All PACER data fields with structured JSON responses.
- **Restrictions:** Paid subscription required. Enterprise pricing.

---

## 3. Police / Crime / Incarceration Records

### Gwinnett County Police - Records Management
- **URL:** https://www.gwinnettcounty.com/departments/police/policereports
- **Access Method:** In-person pickup (7 precinct locations) or via Open Records portal. Reports available 4 business days after filing.
- **Data Fields:** Incident reports, accident reports, citations
- **API:** None. Must use Open Records portal or in-person request.
- **Contact:** 770.513.5000

### CrimeMapping.com - Gwinnett County
- **URL:** https://www.crimemapping.com/map/ga/gwinnettcounty
- **Access Method:** Web map interface. Filter by incident type and date range. Email alerts available.
- **Data Fields:** Incident type, location (approximate), date/time, case number
- **API:** CrimeMapping.com does not offer a public API. Scraping possible but may violate ToS.

### SpotCrime - Gwinnett County
- **URL:** https://spotcrime.com/ga/gwinnett+county
- **Access Method:** Web portal and email alerts
- **Data Fields:** Crime type, location, date
- **API:** SpotCrime offers an API (paid). Contact for details.

### Gwinnett County Sheriff - Jail/Inmate Search (JAIL View)
- **URL:** https://www.gwinnettcountysheriff.com/smartwebclient/
- **Access Method:** Web search by name and booking date
- **Data Fields:** Booking date, inmate number, status (current/released), sex, age, address, assigned cell, charges, bond amount
- **API:** None. Web scraping required.

### Georgia Department of Corrections - Offender Search
- **URL:** https://gdc.georgia.gov/offender-info/find-offender
- **Search Tool:** https://services.gdc.ga.gov/GDC/OffenderQuery/jsp/OffQryForm.jsp
- **Access Method:** Web search by name, GDC ID, case number, age, facility
- **Data Fields:** Name, aliases, GDC ID, facility, sentence status, conviction county, primary offense, physical description, mugshot
- **API:** None public.

### Georgia Sex Offender Registry (GBI)
- **URL:** https://state.sor.gbi.ga.gov/sort_public/
- **Access Method:** Web search by name, address, zip code, county
- **Data Fields:** Name, address, photo, offense details, registration status, physical descriptors
- **API:** None from GBI directly.

### National Sex Offender Public Website (NSOPW)
- **URL:** https://www.nsopw.gov/search-public-sex-offender-registries
- **Access Method:** Federated search across all state registries
- **API:** NSOPW offers a public API for searching across states.

### Third-Party Crime/Offender APIs
- **CrimeoMeter:** https://www.crimeometer.com/sex-offenders-api - Sex offender data by name or zip code. Paid API.
- **OffenderList:** https://offenderlist.us/ - National sex offender database API. Enterprise access.

### BuyCrash - Vehicle Collision Reports
- **URL:** https://www.buycrash.com
- **Access Method:** Search by name or case number. Fee per report.
- **Data Fields:** Collision reports from Gwinnett County Police Department

---

## 4. Business / Corporate Records

### Georgia Secretary of State - Corporations Division
- **URL:** https://ecorp.sos.ga.gov/BusinessSearch
- **Access Method:** Free web search. No account required.
- **Data Fields:** Entity name, control number, entity type (LLC, Corp, LP, etc.), status (active/inactive/dissolved), formation date, registered agent name and address, principal office address, officer/member names
- **API:** No public API documented. Web scraping feasible (standard HTML forms).
- **Search Options:** Entity name, control number, registered agent, officer/owner name
- **Documents:** Articles of Organization/Incorporation, Annual Registrations, Amendments viewable and downloadable as PDFs

### Georgia Secretary of State - Professional Licensing
- **URL:** https://sos.ga.gov/
- **Access Method:** Web search for licensed professionals
- **Data Fields:** License type, licensee name, license number, status, expiration date

---

## 5. Voter Registration

### Georgia Secretary of State - My Voter Page
- **URL:** https://mvp.sos.ga.gov/s/
- **Access Method:** Individual lookup (name + county + DOB)
- **Data Fields:** Registration status, polling place, district information, voter history
- **API:** None public.

### Georgia Secretary of State - Voter Registration List (Bulk)
- **URL:** https://sos.ga.gov/page/order-voter-registration-lists-and-files
- **Access Method:** Ordered via online store or PDF request form. 2-week processing time. Fee applies.
- **Data Fields:** Voter name, residential address, mailing address, race, gender, registration date, last voting date
- **Excluded Fields:** Phone number, DOB, SSN, driver's license number (excluded by law)
- **Restrictions:** Available to public by law but requires formal order and payment.

### Georgia Secretary of State - Voter History Files
- **URL:** https://mvp.sos.ga.gov/s/voter-history-files
- **Access Method:** Downloadable files
- **Data Fields:** Voter participation history by election

---

## 6. Code Violations / Permits / Zoning

### Gwinnett County ZIP Portal (Accela Citizen Access)
- **URL:** https://aca-prod.accela.com/GWINNETT/Welcome.aspx
- **Also:** GwinnettZIP.com
- **Access Method:** Web portal. Free account for enhanced features.
- **Modules:**
  - **Building:** https://aca-prod.accela.com/GWINNETT/Cap/CapHome.aspx?module=Building
  - **Enforcement:** https://aca-prod.accela.com/GWINNETT/Cap/CapHome.aspx?module=Enforce
  - **Planning:** https://aca-prod.accela.com/GWINNETT/Cap/CapHome.aspx?module=Planning
- **Data Fields:** Permit number, type, status, address, applicant, contractor, inspection results, code violation type, case status, zoning case details
- **API:** Accela offers a developer REST API (https://developer.accela.com/). Requires agency authorization. Gwinnett County enrollment status unknown -- contact Planning & Development (678.518.6020).

### Gwinnett County - Building Permits Issued
- **URL:** https://www.gwinnettcounty.com/departments/planningdevelopment/services/buildingservices/buildingpermitsissued
- **Access Method:** Published lists (likely PDF or web table)
- **Data Fields:** Permit number, address, type, contractor, issue date

### Gwinnett County - Code Enforcement
- **URL:** https://www.gwinnettcounty.com/departments/planningdevelopment/services/codeenforcement
- **Contact:** 770.513.5004, CodeEnforcement@GwinnettCounty.com
- **Data Fields:** Violation type (signs, property maintenance, zoning), case status, address

---

## 7. County GIS / Mapping

### Gwinnett County Open Data Portal (ArcGIS Hub)
- **URL:** https://gcgis-gwinnettcountyga.hub.arcgis.com/
- **Datasets:** https://gcgis-gwinnettcountyga.hub.arcgis.com/datasets
- **Access Method:** ArcGIS Hub with REST API endpoints. Download as Shapefile, GeoJSON, CSV, KML.
- **Key Datasets:**
  - Parcels (245,000+ tax parcels)
  - Zoning (dataset ID: aca675dc82a248a0adde4b70eaad0d8d)
  - Roads (2,300+ miles)
  - Schools, utilities, hydrology
  - Aerial photography
- **API:** ArcGIS REST API. Feature service endpoints follow pattern: `https://services.arcgis.com/.../FeatureServer/0/query?where=1=1&outFields=*&f=json`
- **Rate Limits:** Standard ArcGIS Online limits (typically 1000-2000 features per request, paginated).
- **Restrictions:** Free, public access. No authentication required for read operations.
- **Contact:** GISOffice@GwinnettCounty.com

### Gwinnett County GIS Data Browser
- **URL:** https://gis.gwinnettcounty.com/
- **Access Method:** Interactive web map (no special software needed)
- **Data Fields:** Parcel boundaries, owner name, address, zoning, flood zones, council districts, school districts

### Atlanta Regional Commission (ARC) Open Data Hub
- **URL:** https://opendata.atlantaregional.com/
- **Access Method:** ArcGIS Hub portal. Includes metro Atlanta regional datasets covering Gwinnett.
- **Data Fields:** Regional planning data, transportation, demographics, land use

### FEMA Flood Maps - Gwinnett County
- **URL:** https://catalog.data.gov/dataset/digital-flood-insurance-rate-map-database-gwinnett-county-georgia-and-incorporated-areas
- **Access Method:** Downloadable from data.gov
- **Data Fields:** Flood zones, base flood elevations, floodway boundaries

### Data.gov - Gwinnett County Datasets
- **URL:** https://catalog.data.gov/dataset?tags=gwinnett+county
- **Datasets Include:**
  - Watershed boundaries (15 study watersheds)
  - Population densities by watershed (2000-2020)
  - Property parcel building construction dates and densities
  - Stream buffer shapefiles
  - Base flow data (since October 2001)
- **Access Method:** Direct download (Shapefile, CSV)

### Georgia GIO Data Hub (Statewide)
- **URL:** https://data-hub.gio.georgia.gov/
- **Access Method:** ArcGIS Hub with downloads
- **Data Fields:** Statewide GIS layers including parcels, imagery, boundaries, infrastructure

---

## 8. Federal Records

### PACER - U.S. District Court, Northern District of Georgia
- See Section 2 above for full details.
- **URL:** https://ecf.gand.uscourts.gov/

### GSCCCA - UCC Filings (Statewide)
- **URL:** https://search.gsccca.org/UCC_Search/
- **Access Method:** Web search. Free terminal access at clerk offices; online access may require subscription.
- **Search Options:** By name, taxpayer ID, file date, file number, county/region/statewide
- **Data Fields:** Financing statement data, secured party, debtor, filing date, file number, document images
- **Coverage:** All Georgia counties since January 1, 1995
- **Certified Search:** Available to order online

### GSCCCA - Lien Index
- **URL:** https://search.gsccca.org/
- **Access Method:** Web search portal
- **Data Fields:** Real estate and personal property liens, filing details

### Georgia Open Records Act Requests
- **URL:** https://www.gwinnettcounty.com/government/departments/communications/media-relations/open-records
- **Access Method:** Online portal (requires account creation). Covers 22+ county agencies.
- **Response Time:** 3 business days (required by law)
- **Fees:** Electronic records emailed at no charge when available in electronic format. Search/retrieval fees may apply.
- **Excluded:** Vital records, marriage/divorce records, deeds (available through court clerk), court records

---

## 9. Social / Public Presence Data Aggregators

### People Search APIs (Enterprise/Paid)

| Service | URL | API Available | Notes |
|---------|-----|---------------|-------|
| Pipl | https://pipl.com | Yes (Enterprise) | 3B+ identities. Identity resolution API. Used in fraud detection and investigations. |
| People Data Labs | https://peopledatalabs.com | Yes (REST API) | Person search/enrichment API. Structured JSON. |
| Searchbug | https://www.searchbug.com/api/ | Yes (XML/JSON) | People data APIs including name, phone, address lookups. |
| BeenVerified | https://www.beenverified.com | No public API | Subscription service (~$24-37/mo). Aggregates public records + social media. |
| TruthFinder | https://www.truthfinder.com | No public API | Subscription service. Includes dark web monitoring. |
| Spokeo | https://www.spokeo.com | No public API | Aggregates social media, public records, phone data. |

### Free/Open Tools
- **NSOPW API** (sex offender data): https://www.nsopw.gov/
- **Voter registration** (see Section 5)
- **Georgia SOS business search** (see Section 4) - officer/agent names are public

---

## Summary: Best Programmatic Access Points

| Source | API Type | Cost | Best For |
|--------|----------|------|----------|
| Gwinnett County Open Data Portal | ArcGIS REST | Free | GIS/parcel/zoning data |
| CourtListener/RECAP | REST API | Free | Federal court records |
| PACER | Web + API | $0.10/page | Federal court filings |
| GSCCCA | Web (limited API) | Free/Subscription | Deeds, liens, UCC filings |
| GA SOS Business Search | Web scraping | Free | Business entity data |
| Accela (Gwinnett ZIP) | REST API (if authorized) | TBD | Permits, code violations |
| Data.gov | Direct download | Free | Federal datasets on Gwinnett |
| CrimeMapping.com | Web only | Free | Crime incident mapping |
| Gwinnett Sheriff JAIL View | Web scraping | Free | Current inmate/booking data |
| CrimeoMeter | REST API | Paid | Crime/sex offender data |
| People Data Labs | REST API | Paid | People/identity enrichment |
| Voter Registration Lists | Bulk file order | Paid | Voter data |

---

## Key Contacts

| Department | Phone | Email |
|-----------|-------|-------|
| Gwinnett County Open Records | -- | Via online portal |
| GIS Office | -- | GISOffice@GwinnettCounty.com |
| Code Enforcement | 770.513.5004 | CodeEnforcement@GwinnettCounty.com |
| Police Records | 770.513.5000 | -- |
| Sheriff Records | 770.822.3820 | GCSOrecords@gwinnettcounty.com |
| Tax Assessor | -- | Via county website |
| GA SOS Corporations | (404) 656-2817 | -- |
| GSCCCA | -- | Via gsccca.org |

---

*Compiled: March 2026. URLs and access methods subject to change. Always verify current terms of use before implementing automated data collection.*
