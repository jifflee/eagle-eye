# Eagle Eye — Data Source Classification

All sources classified by access method, legal status, and scraping permissions.

## Classification Key

| Category | Meaning | Risk |
|----------|---------|------|
| FREE_API_NO_AUTH | REST API, no key needed | None |
| FREE_API_WITH_KEY | REST API, free registration | None |
| PAID_API | Requires paid subscription | Cost |
| OPEN_SOURCE_TOOL | Self-hosted, runs locally | None |
| BULK_DOWNLOAD | CSV/file download | None |
| WEB_SCRAPER_ALLOWED | Scraping permitted by ToS/robots.txt | Low |
| WEB_SCRAPER_RESTRICTED | Scraping blocked or prohibited | **High** |

---

## FREE API — No Auth Required (14 sources)

Safe to integrate immediately. No keys, no registration.

| Source | URL | Data | Rate Limit |
|--------|-----|------|------------|
| Census Geocoder | geocoding.geo.census.gov | Address → coordinates + census tract | 10K batch |
| EPA ECHO | echo.epa.gov | Environmental facilities, violations | Undocumented |
| SEC EDGAR | data.sec.gov | Corporate filings, officers | 10 req/sec |
| OpenFEMA | fema.gov/api/open | Disasters, flood claims | 10K/call |
| NHTSA vPIC | vpic.nhtsa.dot.gov | VIN decoding, recalls | Undocumented |
| Nominatim (OSM) | nominatim.openstreetmap.org | Geocoding (backup) | 1 req/sec |
| USASpending | api.usaspending.gov | Federal contracts, grants | Undocumented |
| ProPublica Nonprofit | projects.propublica.org/nonprofits/api | IRS 990 data, officers, revenue | ~5K/day |
| FDIC BankFind | banks.data.fdic.gov | Bank branches, financials | Undocumented |
| Overpass (OSM) | overpass-api.de | All POIs/businesses near address | Dynamic (429) |
| NCES Schools | data-nces.opendata.arcgis.com | School locations, demographics | Standard |
| Gwinnett ArcGIS | gcgis-gwinnettcountyga.hub.arcgis.com | Parcels, zoning, property | Standard |
| FCC License View | fcc.gov/developers | FCC licenses by name/location | Undocumented |
| Callook.info | callook.info | Amateur radio licenses | Undocumented |
| Wayback Machine | web.archive.org/cdx | Historical web snapshots | ~0.8 req/sec |

## FREE API — Registration Required (16 sources)

Free account or API key needed. No cost.

| Source | URL | Data | Rate Limit | Key Source |
|--------|-----|------|------------|-----------|
| Census Data API | api.census.gov | Demographics by tract | 500/day no key | api.census.gov/data/key_signup.html |
| FBI Crime Data | api.usa.gov/crime | Crime statistics | Undocumented | api.data.gov/signup |
| CourtListener | courtlistener.com/api | Court records, PACER | 5K/hour | Free account |
| OpenCorporates | api.opencorporates.com | Global company data | 50/day free | API token |
| OpenFEC | api.open.fec.gov | Campaign contributions | ~100/hour | api.data.gov/signup |
| USPTO Trademark | developer.uspto.gov | Patents, trademarks | Undocumented | Free key |
| OSHA/DOL Data | enforcedata.dol.gov | Workplace violations | Undocumented | Free key |
| Geocodio | api.geocod.io | Geocoding + census | 2,500/day free | Free account |
| Whoxy WHOIS | api.whoxy.com | Domain registration | Credits-based | Free tier |
| Mapillary | graph.mapillary.com | Street-level photos | Undocumented | OAuth token |
| Google Civic | civicinfo.googleapis.com | Voter/election by address | 25K/day | GCP key (free) |
| ProPublica Campaign | api.propublica.org | Federal campaign finance | 5K/day | Free key |
| SAM.gov | api.sam.gov | Gov contractors, exclusions | 10/day non-fed | SAM account |
| Copernicus | dataspace.copernicus.eu | Satellite imagery | Quota-based | OAuth 2.0 |
| USGS EarthExplorer | m2m.cr.usgs.gov | Aerial/satellite imagery | Account-based | EROS account |
| GPO GovInfo | api.govinfo.gov | Federal publications | Hourly rolling | data.gov key |
| Hugging Face | huggingface.co | NER, text classification | Monthly credits | HF token |
| KartaView | kartaview.org | Street-level imagery | Undocumented | OAuth |

## BULK DOWNLOAD (1 source)

| Source | URL | Data |
|--------|-----|------|
| PPP Loan Data | sba.gov | 11M+ loan recipients — name, amount, forgiveness |

## OPEN SOURCE TOOLS (4 tools)

Run locally, no API limits. MIT/GPL licensed.

| Tool | URL | What It Does |
|------|-----|-------------|
| Sherlock | github.com/sherlock-project/sherlock | Username search across 400+ platforms |
| SpiderFoot | github.com/smicallef/spiderfoot | Automated OSINT from 200+ sources |
| theHarvester | github.com/laramies/theHarvester | Email/subdomain discovery |
| spaCy | spacy.io | NER entity extraction from text |

## PAID APIs (4 sources)

Require subscription. Consider for premium tier.

| Source | URL | Cost | Data |
|--------|-----|------|------|
| Epieos | epieos.com | €29.99/mo | Email/phone → social accounts |
| IntelX | intelx.io | $2,000+/mo | Breach data, darknet, historical |
| Inforuptcy | inforuptcy.com | $39 day pass | Bankruptcy cases |
| SchoolDigger | developer.schooldigger.com | Paid plans | School rankings (20/day free) |

## WEB SCRAPERS — Restricted / Prohibited (18 sources)

**DO NOT scrape without explicit permission.** These sites block or prohibit automated access.

### PROHIBITED (ToS explicitly bans scraping)

| Source | Why | Risk |
|--------|-----|------|
| GSCCCA (deeds, UCC, liens) | ToS bans robots/spiders; criminal/civil penalties | **HIGH** |
| re:SearchGA (Tyler) | ToS prohibits bulk copying/database storage | **HIGH** |
| Accela / Gwinnett Permits | Accela corporate ToS prohibits automated access | **HIGH** |
| Gwinnett eCourt | 45 searches/day hard cap | **HIGH** |
| NSOPW | CAPTCHA-gated, no API | **HIGH** |
| GA MVP Voter | robots.txt disallows all search paths | **HIGH** |
| qPublic | Blocks AI crawlers; prohibits AI training | **MODERATE** |

### UNCLEAR (no explicit ToS found, no robots.txt)

| Source | Status | Recommendation |
|--------|--------|----------------|
| GA SOS eCorp | robots.txt returns 403 | Use manual lookup; request API access |
| Gwinnett Courts | No robots.txt (404) | Use Open Records request instead |
| GBI Sex Offender | CAPTCHA-gated | Use NSOPW API if available |
| Gwinnett Sheriff JAIL | No robots.txt | Use Open Records request |
| GA Ethics Commission | No robots.txt (404) | Public records by law; proceed cautiously |
| GA DOR Lien Search | JavaScript-heavy; unclear | Manual lookup only |
| GA SOS License | robots.txt returns 403 | Use manual lookup |
| GNR Health Inspections | robots.txt returns 403 | Request data via Open Records |
| GA DOC Offender Search | No robots.txt (404) | Proceed cautiously; public safety data |

---

## Action Items

### Immediately Safe to Build (Tier 1 — no risk)
1. OpenFEC API — campaign contributions
2. USASpending API — government contracts
3. ProPublica Nonprofit API — nonprofit officers
4. FDIC BankFind API — bank branches
5. Overpass API — POIs near address
6. FCC License View API — FCC licenses
7. Wayback Machine CDX — archived websites
8. Callook.info — amateur radio

### Build with Free Registration (Tier 2 — no risk)
9. Geocodio — better geocoding
10. Google Civic Info — voter/election data
11. Mapillary — street photos
12. ProPublica Campaign Finance — donations
13. USPTO — trademarks/patents
14. GPO GovInfo — federal publications

### Disable or Replace Scrapers (Tier 3 — legal risk)
15. GSCCCA → Replace with Open Records requests
16. qPublic → Replace with Gwinnett ArcGIS REST API
17. re:SearchGA → Replace with CourtListener
18. Accela → Submit Open Records request for permit data
19. GA MVP Voter → Use voter file bulk purchase from SOS

### Consider for Premium Tier (Tier 4 — paid)
20. Epieos — social media discovery
21. IntelX — breach/darknet data
