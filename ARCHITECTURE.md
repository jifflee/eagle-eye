# Eagle Eye - System Architecture

## Overview

Eagle Eye is a modular, open-source OSINT intelligence platform that transforms a single address input into a comprehensive entity relationship graph. The system discovers residents, businesses, court records, property data, and more — then visualizes all connections in an interactive Palantir-style graph UI.

---

## System Layers

```
┌─────────────────────────────────────────────────────────────────┐
│ LAYER 1: PRESENTATION (React + Neovis.js + TailwindCSS)        │
│ ├─ Address Input Form                                           │
│ ├─ Interactive Graph Visualization                              │
│ ├─ Entity Detail Panels                                         │
│ └─ Search, Filter, Timeline                                     │
├─────────────────────────────────────────────────────────────────┤
│ LAYER 2: API & ORCHESTRATION (FastAPI)                          │
│ ├─ REST API Gateway                                             │
│ ├─ Enrichment Pipeline Orchestrator                             │
│ ├─ Rate Limit Manager                                           │
│ ├─ Cache Manager (Redis)                                        │
│ └─ Audit & Provenance Logger                                    │
├─────────────────────────────────────────────────────────────────┤
│ LAYER 3: DATA COLLECTION (Connector Framework)                  │
│ ├─ Connector Registry (plugin system)                           │
│ ├─ Tier 1: Free APIs (Census, FBI, EPA, SEC, etc.)             │
│ ├─ Tier 2: Registration/Scraping (County, Courts)              │
│ ├─ Tier 3: Limited Free (Hunter.io, NumVerify)                 │
│ └─ Data Validators & Normalization                             │
├─────────────────────────────────────────────────────────────────┤
│ LAYER 4: STORAGE & GRAPH (Neo4j + PostgreSQL)                   │
│ ├─ Neo4j Community (entities + relationships)                   │
│ ├─ PostgreSQL (provenance, audit logs, metadata)                │
│ ├─ Redis (cache, rate limits, sessions)                         │
│ └─ Full-Text Search Index                                       │
├─────────────────────────────────────────────────────────────────┤
│ LAYER 5: QUERY & ANALYTICS                                      │
│ ├─ Relationship Discovery Engine                                │
│ ├─ Graph Search & Path Finding                                  │
│ └─ Aggregation & Reporting                                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Technology Stack

### Backend

| Component | Choice | Justification |
|-----------|--------|---------------|
| Language | Python 3.11+ | OSINT tooling ecosystem, async support |
| Framework | FastAPI | Async-native, auto OpenAPI docs, dependency injection |
| Graph DB | Neo4j Community | Industry standard for relationship graphs, Cypher queries |
| Metadata DB | PostgreSQL | Provenance tracking, audit logs, ACID |
| Cache | Redis | Rate limit tracking, session storage, distributed locks |
| Task Queue | Celery + Redis | Async enrichment pipeline, retry logic |
| HTTP Client | httpx (async) | Connection pooling, retry strategies |

### Frontend

| Component | Choice | Justification |
|-----------|--------|---------------|
| Framework | React 18+ | Rich ecosystem for graph visualization |
| Graph Viz | Neovis.js / Vis.js | Purpose-built for Neo4j, interactive rendering |
| Styling | TailwindCSS + shadcn/ui | Modern, accessible, rapid development |
| State | TanStack Query + Zustand | Server state sync + lightweight client state |
| Build | Vite | Fast dev server, optimized production builds |

### Infrastructure

| Component | Choice |
|-----------|--------|
| Containers | Docker + Docker Compose (dev) |
| Orchestration | Kubernetes (prod) |
| CI/CD | GitHub Actions |
| VCS | Git (GitHub) |

---

## Data Model

### Core Entities (Neo4j Nodes)

```
PERSON          - name, aliases, DOB, gender
ADDRESS         - street, city, state, zip, lat/long, type
PROPERTY        - APN, owner, assessed value, zoning, year built
BUSINESS        - name, entity type, formation date, officers
CASE            - case number, court, type, parties, disposition
VEHICLE         - VIN, make/model/year, registration
CRIME_RECORD    - incident type, date, location, jurisdiction
SOCIAL_PROFILE  - platform, username, profile URL
PHONE_NUMBER    - number, carrier, line type
EMAIL_ADDRESS   - email, domain, breach count
ENV_FACILITY    - name, type, violations, compliance status
CENSUS_TRACT    - tract number, demographics, income, housing
```

### Relationship Types (Neo4j Edges)

All edges carry: `{sources[], confidence, from_date, to_date}`

```
PERSON --[LIVES_AT]--> ADDRESS
PERSON --[OWNS_PROPERTY]--> PROPERTY
PERSON --[IS_RELATIVE_OF]--> PERSON
PERSON --[WORKS_FOR]--> BUSINESS
PERSON --[OWNS_BUSINESS]--> BUSINESS
PERSON --[NAMED_IN_CASE]--> CASE
PERSON --[REGISTERED_VEHICLE]--> VEHICLE
PERSON --[HAS_SOCIAL_PROFILE]--> SOCIAL_PROFILE
PERSON --[HAS_PHONE]--> PHONE_NUMBER
PERSON --[HAS_EMAIL]--> EMAIL_ADDRESS
BUSINESS --[LOCATED_AT]--> ADDRESS
BUSINESS --[OWNS_PROPERTY]--> PROPERTY
BUSINESS --[AFFILIATED_WITH]--> BUSINESS
ADDRESS --[IN_CENSUS_TRACT]--> CENSUS_TRACT
ADDRESS --[HAS_CRIME_NEAR]--> CRIME_RECORD
ADDRESS --[HAS_ENV_FACILITY]--> ENV_FACILITY
```

### Provenance Model (PostgreSQL)

Every attribute carries source attribution:

```sql
source_records (
  id UUID PRIMARY KEY,
  entity_id UUID,
  connector_name VARCHAR,
  confidence_score FLOAT,
  retrieval_date TIMESTAMP,
  expiration_date TIMESTAMP,
  raw_data JSONB,
  attribute_hash VARCHAR
)
```

---

## Connector Framework

### Base Class

```python
class BaseConnector(ABC):
    name: str                    # e.g., "census_geocoder"
    tier: Literal[1, 2, 3]
    requires_auth: bool = False
    rate_limit: RateLimit

    async def discover(self, entity) -> list[Entity]: ...
    async def enrich(self, entity) -> dict: ...
    async def validate(self) -> bool: ...
```

### Connector Registry

Connectors are plugins registered at startup. Adding a new source = adding one file to `connectors/tierN/`.

### Data Sources by Tier

**Tier 1 (Free, no auth):** Census Geocoder, Census Data API, FBI Crime Data, EPA ECHO, SEC EDGAR, CourtListener, OpenFEMA, OSM Nominatim, NHTSA vPIC

**Tier 2 (Free, registration/scraping):** Gwinnett County ArcGIS, GA Secretary of State, Gwinnett Courts, GSCCCA, qPublic, Gwinnett Sheriff JAIL View, GBI Sex Offender Registry

**Tier 3 (Free with limits):** OpenCorporates, Google Places, Hunter.io, NumVerify

---

## Enrichment Pipeline

```
1. ADDRESS INPUT
   ↓
2. GEOCODING (Census Geocoder → lat/long + tract)
   ↓
3. ADDRESS ENRICHMENT (parallel Tier 1)
   Census Data, FBI Crime, EPA ECHO, OpenFEMA, FCC
   ↓
4. RESIDENT DISCOVERY (people search, property records)
   ↓
5. PERSON ENRICHMENT (per person, parallel)
   Sherlock, Hunter.io, CourtListener, SEC, NSOPW
   ↓
6. ENTITY LINKING (dedup, merge, relationship detection)
   ↓
7. GRAPH READY (visualization update)
```

### Discovery Algorithm

- Recursive, depth-limited (default 3 hops)
- Visited set prevents cycles
- Parallel connector queries with rate limiting
- Circuit breaker for failing sources

---

## API Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/v1/investigation` | Start investigation from address |
| GET | `/api/v1/investigation/{id}` | Get full graph + status |
| GET | `/api/v1/entity/{id}` | Entity details with provenance |
| POST | `/api/v1/entity/{id}/expand` | Load more relationships |
| GET | `/api/v1/enrichment/status/{id}` | Pipeline progress |
| POST | `/api/v1/enrichment/{id}/control` | Pause/resume/cancel |
| POST | `/api/v1/search` | Full-text entity search |
| GET | `/api/v1/sources` | Available data sources |
| POST | `/api/v1/investigation/{id}/save` | Save investigation |
| GET | `/api/v1/saved-investigations` | List saved |
| GET | `/api/v1/investigation/{id}/export` | Export JSON/CSV |

---

## Project Structure

```
eagle-eye/
├── docs/                          # Specifications
├── backend/
│   ├── app/
│   │   ├── main.py                # FastAPI entry
│   │   ├── config.py              # Environment config
│   │   ├── api/v1/                # Route handlers
│   │   ├── models/                # Pydantic schemas, Neo4j models
│   │   ├── connectors/
│   │   │   ├── base.py            # Abstract connector
│   │   │   ├── registry.py        # Plugin discovery
│   │   │   ├── tier1/             # Free API connectors
│   │   │   ├── tier2/             # Scraping connectors
│   │   │   └── tier3/             # Limited free connectors
│   │   ├── enrichment/            # Pipeline orchestration
│   │   ├── cache/                 # Redis + offline cache
│   │   ├── rate_limiting/         # Rate limit enforcement
│   │   ├── database/              # Neo4j + Postgres drivers
│   │   └── utils/                 # HTTP client, normalization
│   └── tests/
├── frontend/
│   ├── src/
│   │   ├── components/
│   │   │   ├── Graph/             # Visualization
│   │   │   ├── Entity/            # Detail panels
│   │   │   ├── Input/             # Address form
│   │   │   ├── Enrichment/        # Status displays
│   │   │   └── Common/            # Shared UI
│   │   ├── hooks/                 # useGraph, useSearch, etc.
│   │   ├── api/                   # API client
│   │   ├── stores/                # Zustand state
│   │   └── pages/                 # Route pages
│   └── tests/
├── docker-compose.yml
└── scripts/
```

---

## Key Architectural Patterns

1. **Connector Plugin Pattern** — Each source is independent; add without touching core
2. **Cache-Aside** — Check Redis before API calls; write-through on hits
3. **Circuit Breaker** — Stop calling failing connectors; exponential backoff
4. **Provenance-First** — Every attribute carries source, confidence, timestamp
5. **Async Pipeline** — Tier 1 returns fast; Tier 2/3 enrich in background
6. **Lazy Graph Loading** — Render visible nodes first; load offscreen on demand

---

## Related Documents

- [PRODUCT_SPEC.md](./PRODUCT_SPEC.md) — Full product specification and user stories
- [DESIGN_SYSTEM.md](./DESIGN_SYSTEM.md) — Visual design tokens and component styles
- [API_SPEC.md](./API_SPEC.md) — Detailed REST API specification
- [OSINT_DATA_SOURCES.md](./OSINT_DATA_SOURCES.md) — Free OSINT source inventory
- [OSINT_DATA_SOURCES_GWINNETT_COUNTY.md](./OSINT_DATA_SOURCES_GWINNETT_COUNTY.md) — County-specific sources
