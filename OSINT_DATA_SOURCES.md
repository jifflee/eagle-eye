# Free OSINT Data Sources & Tools for Address and People Profiling

Comprehensive reference of free, programmatically accessible open source intelligence (OSINT) data sources organized by category.

---

## 1. People Search / Public Records (Free)

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **SearchPeopleFree** | https://www.searchpeoplefree.com/ | No (web only) | Fully free web search | Name, address, phone, relatives, address history | Direct address search |
| **UnMask.com** | https://unmask.com/ | No (web only) | Fully free | Contact info, phone, email, relatives, address history | Direct address/person lookup |
| **FreePeopleSearch** | https://freepeoplesearch.com/ | No (web only) | Free basic info; paid for detailed reports | Name, address, phone | Address search supported |
| **Open People Search API** | https://www.openpeoplesearch.com/Public-Record-Lookup-Api | REST API | Limited free tier | Consumer/business records from 4,000+ government sources across 50 states | Address-based lookups |
| **USA People Search (RapidAPI)** | https://rapidapi.com/digital-insights-digital-insights-default/api/usa-people-search-public-records | REST API | RapidAPI free tier (limited calls) | Public records, addresses, phones | Reverse address lookup |

**Notes:** Most truly free people search services are web-only. API-based services typically have limited free tiers before requiring payment.

---

## 2. Social Media / Username OSINT

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **Sherlock** | https://github.com/sherlock-project/sherlock | CLI tool (Python) | Fully free, open source | Username existence across 400+ social platforms | Correlate usernames found at an address to social profiles |
| **Sherlock on Apify** | https://apify.com/misceres/sherlock | REST API (cloud) | Apify free tier | Same as Sherlock, cloud-hosted | Same as above |
| **SherlockOSINT.com** | https://sherlockosint.com/ | Web interface | Free web searches | Username search across platforms | N/A |

**Installation (Sherlock CLI):**
```bash
pipx install sherlock-project
# or
pip install --user sherlock-project
```

**Key Features:**
- No API keys or login credentials required
- Checks 400+ websites by constructing expected profile URLs
- Output to text, CSV, or XLSX
- Only accesses publicly available information

---

## 3. Property & Real Estate (Free)

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **Zillow API** | https://www.zillowgroup.com/developers/ | REST API | Free for non-commercial use (approval required) | Zestimates, basic market data, property details | Direct address lookup |
| **OpenStreetMap / Nominatim** | https://nominatim.org/ | REST API | Free (1 req/sec limit) | Address geocoding, reverse geocoding, place data | Address to coordinates |
| **Homesage.ai** | https://homesage.ai/ | REST API | 500 free sandbox credits | Property attributes, valuations, AI-validated data | Address-based property lookup |
| **Particle Space** | https://docs.particlespace.com/ | REST API | 200 free requests/month | Open-sourced listing data similar to Zillow | Address-based search |
| **Redfin** | https://www.redfin.com/ | Downloadable data / web scraping | Free market reports | Market analysis, property history, sale prices | Address search on website |

**Notes:** Zillow API access has become increasingly restrictive; approval process can take weeks. OpenStreetMap/Nominatim is the most reliable free option for geocoding.

---

## 4. Business & Corporate (Free)

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **OpenCorporates** | https://api.opencorporates.com/ | REST API | Free for open data projects (same open licence) | Company data across 170+ jurisdictions, largest open corporate database | Search companies registered at an address |
| **SEC EDGAR** | https://www.sec.gov/search-filings/edgar-application-programming-interfaces | REST API (data.sec.gov) | Fully free, no auth required | 10-Q, 10-K, 8-K filings, XBRL financial data, submission history | Look up companies/officers linked to addresses |
| **State Business Registries** | Varies by state (e.g., CA: https://bizfileonline.sos.ca.gov/) | Varies (many have search interfaces) | Free (government records) | Business registrations, officers, agents, addresses | Direct registered agent/address search |

**SEC EDGAR Key Details:**
- RESTful APIs at `data.sec.gov` deliver JSON data
- No authentication or API keys required
- Includes submissions history by filer and XBRL financial statement data

**OpenCorporates Key Details:**
- Free for non-commercial/open data use
- Commercial API starts at GBP 2,250/year
- API Reference: https://api.opencorporates.com/documentation/API-Reference

---

## 5. Court & Legal (Free)

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **CourtListener** | https://www.courtlistener.com/ | REST API (v4.3) | Free (non-profit, 501(c)(3)) | Federal/state case law, PACER data, oral arguments | Search cases involving people/entities at addresses |
| **RECAP Archive** | https://www.courtlistener.com/recap/ | REST API | Free | Millions of PACER documents crowdsourced via browser extensions | Same as CourtListener |
| **CourtListener Semantic Search** | https://www.courtlistener.com/help/api/rest/ | REST API | Free | Natural language legal search (launched 2025) | Search by party name/address |
| **PACER** | https://pacer.uscourts.gov/ | Web interface | Free opinions; $0.10/page for other documents | Federal court filings, dockets, opinions | Party/address search |

**CourtListener Key Details:**
- Over 100 million API requests processed
- Bulk data downloads available
- API docs: https://www.courtlistener.com/help/api/
- RECAP Fetch API uses your PACER credentials (PACER fees still apply)

---

## 6. Crime & Safety (Free)

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **FBI Crime Data Explorer** | https://cde.ucr.cjis.gov/ | REST API | Fully free | UCR/NIBRS crime statistics by location, agency, crime type | Search by state/county/town |
| **FBI Crime Data API** | https://github.com/fbi-cde/crime-data-api | REST API | Fully free | SRS and NIBRS data in JSON/CSV | Aggregate crime data near addresses |
| **NIBRS National Estimates API** | https://bjs.ojp.gov/national-incident-based-reporting-system-nibrs-national-estimates-api | REST API | Fully free | Incident, offense, victim-level crime estimates | National/regional crime data |
| **NCVS API** | https://bjs.ojp.gov/ | REST API | Fully free | Victimization data (JSON, XML, CSV) | National survey data |
| **SpotCrime** | https://spotcrime.com/ | No public API (email api@spotcrime.com for commercial) | Free web search & alerts | Arrests, arson, assault, burglary, robbery, shooting, theft, vandalism | Direct address search on map |
| **CrimeMapping / Community Crime Map** | https://communitycrimemap.com/ | Web interface | Free | Local crime incidents from police agencies | Address-based crime search |
| **NSOPW** | https://www.nsopw.gov/ | Web search only (no public API) | Fully free | Sex offender registries from all 50 states + territories | Search by address/zip/name |
| **Offenders.io** | https://offenders.io/ | REST API | Pay-as-you-go (no free tier, but no minimums) | 900K+ sex offender records, 1M+ crimes | Address-radius search |

---

## 7. Government Open Data

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **US Census Bureau API** | https://www.census.gov/data/developers/data-sets.html | REST API | Fully free | Demographics, income, population, housing by tract/block/county | Address to census tract to demographics |
| **Census Geocoder** | https://geocoding.geo.census.gov/geocoder/ | REST API | Fully free (batch up to 10,000) | Address to lat/long + census geographies (state, county, tract, block) | Direct address input |
| **Data.gov** | https://catalog.data.gov/ | Various APIs | Fully free | Thousands of federal datasets | Many datasets indexed by location |
| **OpenFEMA API** | https://www.fema.gov/about/openfema/api | REST API | Fully free | Disaster declarations, NFIP flood claims, grants, mitigation | Flood risk/disaster history by location |
| **FEMA Flood Map (NFHL)** | https://msc.fema.gov/ | GIS services + viewer | Free viewer; API via National Flood Data requires key | Flood zones, flood insurance rate maps | Direct address flood zone lookup |
| **EPA Envirofacts API** | https://www.epa.gov/enviro/envirofacts-data-service-api | REST API | Fully free | Environmental data from TRI, RCRA, SDWIS, Superfund, etc. | Facility search by location |
| **EPA ECHO** | https://echo.epa.gov/ | REST API (web services) | Fully free | 800,000+ facilities: inspections, violations, enforcement actions, penalties | Address/location facility search |
| **FCC National Broadband Map** | https://broadbandmap.fcc.gov/ | REST API (token required, free) | Free (registration required) | Broadband availability by address, provider coverage | Direct address lookup |

**Census Geocoder Python Library:**
```bash
pip install censusgeocode
```

**EPA ECHO Key Details:**
- 130+ data fields per facility
- Covers Clean Air Act, Clean Water Act, RCRA, Safe Drinking Water Act
- Web services docs: https://echo.epa.gov/tools/web-services

---

## 8. Geospatial / Mapping (Free)

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **OpenStreetMap Nominatim** | https://nominatim.org/ | REST API | Free (1 req/sec, no heavy use) | Forward/reverse geocoding, address search | Address to coordinates and back |
| **US Census Geocoder** | https://geocoding.geo.census.gov/ | REST API | Fully free, batch up to 10K | Coordinates + census geographies | Direct address geocoding |
| **Google Maps/Places API** | https://developers.google.com/maps/documentation/places/web-service | REST API | ~10,000 free calls/month (Essentials tier, post-March 2025) | Places, addresses, business info, reviews | Address validation & enrichment |
| **FFIEC Geocoder** | https://geomap.ffiec.gov/ | Web + API | Free | Census tract, MSA, demographic data for addresses | Address to census/demographic data |
| **Geoapify** | https://www.geoapify.com/ | REST API | 3,000 free requests/day | Geocoding, reverse geocoding, places, routing | Address-based queries |

**Nominatim Usage Policy:**
- Maximum 1 request per second
- Must provide valid HTTP Referer or User-Agent
- Self-hosting recommended for heavy use (fully open source)
- Endpoints: `/search` (geocoding), `/reverse` (reverse geocoding)

---

## 9. OSINT Frameworks & Tools (Open Source)

| Tool | URL | Type | Free? | Key Capabilities |
|------|-----|------|-------|-----------------|
| **SpiderFoot** | https://github.com/smicallef/spiderfoot | Python, web GUI | Fully free, open source | 200+ data sources, automated OSINT, supports IP/domain/email/name/address. Integrates with Shodan, VirusTotal, HIBP |
| **theHarvester** | https://github.com/laramies/theHarvester | Python CLI | Fully free, open source | Emails, subdomains, IPs from 30+ sources including search engines and PGP servers |
| **Recon-ng** | https://github.com/lanmaster53/recon-ng | Python CLI (modular) | Fully free, open source | 35+ modules for reconnaissance from search engines, social media, public databases |
| **Maltego CE** | https://www.maltego.com/use-for-free/ | Desktop app (Java) | Free Community Edition (200 monthly credits) | Visual link analysis, entity relationship mapping, transform hub (limited in CE: 12 results per transform, 10K entities per graph) |
| **OSINT Framework** | https://osintframework.com/ | Web directory | Fully free | Curated directory of hundreds of free OSINT tools organized by data type (username, email, domain, social media, etc.) |
| **Shodan** | https://www.shodan.io/ | REST API | Free tier (limited) | Internet-connected device search, exposed services, IoT | Search devices at IP addresses |

**SpiderFoot Key Details:**
- Scans: IP addresses, domain names, hostnames, ASNs, subnets, email addresses, person names
- Web GUI for easy use
- Install: `pip install spiderfoot`

---

## 10. Phone / Email Lookup (Free)

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **Have I Been Pwned (HIBP)** | https://haveibeenpwned.com/ | REST API (v3) | Pwned Passwords API: fully free, no key needed. Email breach search: requires API key (paid subscription) | Breach data, paste data, pwned passwords | Check if email/phone from address profile appears in breaches |
| **Hunter.io** | https://hunter.io/ | REST API | Free tier (25 searches/month + 50 verifications/month) | Email finder, email verifier, domain search | Find emails associated with domains/companies at an address |
| **NumVerify** | https://numverify.com/ | REST API | 100 free requests/month | Phone validation, carrier lookup, line type, location (232 countries) | Validate phone numbers found for address occupants |
| **NumValidate** | https://numvalidate.com/ | REST API | Free tier available | Phone number validation | Same as NumVerify |

**Hunter.io Free Tier Details:**
- 25 email searches/month
- 50 email verifications/month
- No paid plan required for API access at free tier

---

## 11. Vehicle / License (Free)

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **NHTSA vPIC API** | https://vpic.nhtsa.dot.gov/api/ | REST API | Fully free, no registration, 24/7 | VIN decoding, make/model/year, vehicle specs, 25+ API methods | Link vehicles to address occupants |
| **NHTSA VIN Decoder** | https://www.nhtsa.gov/vin-decoder | Web interface | Fully free | Same as API, web-based | Same |
| **NHTSA Recalls API** | https://www.nhtsa.gov/nhtsa-datasets-and-apis | REST API | Fully free | Vehicle recalls, complaints, investigations | Check recall status of vehicles at an address |
| **NHTSA Standalone DB** | https://vpic.nhtsa.dot.gov/ | Downloadable (SQL Server/PostgreSQL) | Fully free | Full vPIC database for local VIN decoding | Offline batch processing |

**NHTSA vPIC Key Details:**
- Supports Model Years 1981+
- Partial VIN decoding supported (< 17 characters)
- No rate limits documented
- Python wrapper: `pip install vpic-api`

---

## 12. Dark Web / Breach Data (Free/Legal)

| Source | URL | API? | Free Tier | Data Available | Address Link |
|--------|-----|------|-----------|---------------|--------------|
| **Have I Been Pwned** | https://haveibeenpwned.com/ | REST API | Pwned Passwords: free. Breach search: paid API key required | 14B+ breached accounts, passwords, pastes | Check credentials of address occupants |
| **DeHashed** | https://dehashed.com/ | REST API | Free web search (limited); 10 free monitor tasks. API: $3 per 100 credits | 13.3B+ records: names, emails, usernames, IPs, addresses, phones, VINs | Search by address, phone, name directly |
| **IntelX (Intelligence X)** | https://intelx.io/ | REST API | Free tier (limited searches) | Historical web pages, breach data, darknet content | Search by email/domain/IP |

**DeHashed Key Details:**
- Searchable fields: name, email, username, IP, physical address, phone, VIN, domain
- API requires paid credits ($3/100 credits) but no subscription minimum
- Web domain registration search (added 2025)

---

## Integration Architecture for Address-Based Profiling

The following shows how these sources connect for building an address profile:

```
INPUT: Street Address
    |
    v
[Census Geocoder] --> lat/long + Census tract/block
    |
    +---> [Census API] --> Demographics, income, population for that tract
    +---> [FEMA NFHL] --> Flood zone designation
    +---> [EPA ECHO] --> Nearby environmental facilities/violations
    +---> [FBI Crime Data] --> Crime stats for county/city
    +---> [FCC Broadband] --> Internet availability
    |
[People Search] --> Names of residents/owners
    |
    +---> [Sherlock] --> Social media profiles
    +---> [Hunter.io] --> Associated email addresses
    +---> [HIBP] --> Breach exposure
    +---> [CourtListener] --> Court cases
    +---> [SEC EDGAR] --> Business filings
    +---> [OpenCorporates] --> Company registrations
    +---> [NSOPW] --> Sex offender check
    |
[Property Data] --> Ownership, valuation, tax history
    |
    +---> [Zillow/Homesage] --> Property value, sale history
    +---> [County Assessor] --> Tax records (varies by county)
    |
[NHTSA] --> Vehicle info (if VIN available)
[NumVerify] --> Phone number validation
```

---

## Quick-Start: Fully Free, No-Auth APIs

These require zero signup and no API keys:

1. **SEC EDGAR** - `https://data.sec.gov/` (JSON, add User-Agent header)
2. **NHTSA vPIC** - `https://vpic.nhtsa.dot.gov/api/` (JSON/XML)
3. **Census Geocoder** - `https://geocoding.geo.census.gov/geocoder/` (JSON)
4. **Census Data API** - `https://api.census.gov/data/` (JSON, key recommended but not required for low volume)
5. **FBI Crime Data API** - `https://api.usa.gov/crime/fbi/` (JSON/CSV)
6. **EPA Envirofacts** - `https://enviro.epa.gov/` (JSON/XML/CSV)
7. **OpenStreetMap Nominatim** - `https://nominatim.openstreetmap.org/` (JSON, 1 req/sec)
8. **OpenFEMA** - `https://www.fema.gov/api/open/` (JSON)
9. **HIBP Pwned Passwords** - `https://api.pwnedpasswords.com/` (k-Anonymity model)

---

## Legal & Ethical Considerations

- All sources listed are **publicly available** and **legal to access** in the United States
- Many government APIs have **terms of service** requiring proper attribution
- **Rate limits** must be respected (especially Nominatim's 1 req/sec)
- **SEC EDGAR** requires a User-Agent header identifying your application
- Social media scraping may violate platform ToS even if data is public
- Breach data usage should comply with applicable privacy laws
- **CFAA** (Computer Fraud and Abuse Act) applies -- only access data you are authorized to access
- Consider **GDPR** implications if profiling EU residents
- Many states have **data broker registration** requirements if you are reselling data
