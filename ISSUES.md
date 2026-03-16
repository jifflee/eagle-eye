# Eagle Eye - Epic & Issue Breakdown

## Overview

7 Epics, 45 Issues, organized by dependency order. Each issue includes acceptance criteria, sub-tasks, effort estimate (S/M/L/XL), and dependencies.

**Effort Key:** S = 1-2 days, M = 3-5 days, L = 1-2 weeks, XL = 2+ weeks

---

## Epic 1: Project Foundation & Infrastructure

> Set up the monorepo, tooling, CI/CD, and local development environment.

### Issue 1.1: Initialize monorepo structure
**Effort:** S
**Dependencies:** None
**Description:** Create the project skeleton with backend (Python/FastAPI) and frontend (React/Vite) directories, shared configs, and documentation structure.

**Sub-tasks:**
- [ ] Create root directory structure (`backend/`, `frontend/`, `docs/`, `scripts/`)
- [ ] Initialize Python project with `pyproject.toml` (Python 3.11+, FastAPI, httpx, celery, neo4j-driver, psycopg)
- [ ] Initialize React project with Vite + TypeScript
- [ ] Create `.gitignore` (Python, Node, env files, IDE, OS)
- [ ] Create `.env.example` with all required env vars (Neo4j, PostgreSQL, Redis URLs, API keys)
- [ ] Create `LICENSE` (MIT or Apache 2.0)
- [ ] Create root `README.md` with project overview and quick start

**Acceptance Criteria:**
- `pip install -e .` works in `/backend`
- `npm install && npm run dev` works in `/frontend`
- No secrets in any committed files
- `.env` is in `.gitignore`

---

### Issue 1.2: Docker Compose local development environment
**Effort:** M
**Dependencies:** 1.1
**Description:** Create Docker Compose setup that runs Neo4j, PostgreSQL, Redis, backend, and frontend with hot reload.

**Sub-tasks:**
- [ ] Write `Dockerfile` for backend (Python 3.11, FastAPI, uvicorn)
- [ ] Write `Dockerfile` for frontend (Node 20, Vite dev server)
- [ ] Write `docker-compose.yml` with services: neo4j, postgres, redis, backend, frontend
- [ ] Configure Neo4j Community Edition with APOC plugin
- [ ] Configure PostgreSQL with init script for schema
- [ ] Configure Redis for caching and Celery broker
- [ ] Add volume mounts for hot reload (backend + frontend source)
- [ ] Write `scripts/setup_dev_env.sh` for first-time setup
- [ ] Document setup in README

**Acceptance Criteria:**
- `docker compose up` starts all 5 services
- Backend accessible at `localhost:8000`
- Frontend accessible at `localhost:5173`
- Neo4j browser accessible at `localhost:7474`
- Hot reload works for both backend and frontend code changes
- Data persists across container restarts (volumes)

---

### Issue 1.3: CI/CD pipeline with GitHub Actions
**Effort:** S
**Dependencies:** 1.1
**Description:** Set up CI pipeline for linting, type checking, and testing on PRs.

**Sub-tasks:**
- [ ] Create `.github/workflows/ci.yml`
- [ ] Backend: ruff lint + format check, mypy type check, pytest
- [ ] Frontend: eslint, tsc --noEmit, vitest
- [ ] Run on push to `main` and on PRs
- [ ] Add status badges to README

**Acceptance Criteria:**
- CI runs on every PR
- Fails on lint errors, type errors, or test failures
- Completes in under 5 minutes

---

### Issue 1.4: Database schema initialization
**Effort:** M
**Dependencies:** 1.2
**Description:** Create Neo4j constraints/indexes and PostgreSQL schema for provenance tracking.

**Sub-tasks:**
- [ ] Write Neo4j Cypher schema script (`database/migrations/neo4j_schema.cypher`)
  - [ ] Uniqueness constraints on entity IDs
  - [ ] Indexes on entity names, addresses, case numbers
  - [ ] Full-text indexes on person names, business names
- [ ] Write PostgreSQL schema (`database/migrations/postgres_schema.sql`)
  - [ ] `source_records` table (provenance)
  - [ ] `investigations` table (saved investigations)
  - [ ] `audit_log` table (user actions)
  - [ ] `connector_status` table (health tracking)
- [ ] Write migration runner script
- [ ] Write `scripts/demo_data.py` to load sample graph data for development

**Acceptance Criteria:**
- Neo4j schema applies cleanly on fresh database
- PostgreSQL migrations are idempotent
- Demo data loads 20+ entities with relationships
- Can query demo data from Neo4j browser

---

## Epic 2: Backend Core & API

> Build the FastAPI application, core models, and REST API endpoints.

### Issue 2.1: FastAPI application scaffold
**Effort:** S
**Dependencies:** 1.1
**Description:** Create the FastAPI app with CORS, error handling, health check, and OpenAPI docs.

**Sub-tasks:**
- [ ] Create `app/main.py` with FastAPI initialization
- [ ] Configure CORS middleware (allow frontend origin)
- [ ] Create `app/config.py` with Pydantic Settings (env var loading)
- [ ] Add global exception handlers (404, 422, 500)
- [ ] Add `/health` endpoint (checks Neo4j, PostgreSQL, Redis connectivity)
- [ ] Configure structured logging
- [ ] Verify OpenAPI docs at `/docs`

**Acceptance Criteria:**
- `GET /health` returns `{"status": "ok"}` when all services are up
- `GET /docs` shows Swagger UI
- CORS allows frontend origin
- Structured JSON logging to stdout

---

### Issue 2.2: Pydantic models and entity schemas
**Effort:** M
**Dependencies:** 2.1
**Description:** Define all request/response schemas and entity models.

**Sub-tasks:**
- [ ] Create `models/entities.py` — Person, Address, Property, Business, Case, Vehicle, CrimeRecord, SocialProfile, PhoneNumber, EmailAddress, EnvironmentalFacility, CensusTract
- [ ] Create `models/relationships.py` — All relationship types with properties
- [ ] Create `models/schemas.py` — API request/response models
  - [ ] `InvestigationRequest` (address input + config)
  - [ ] `InvestigationResponse` (entities, relationships, metadata)
  - [ ] `EntityResponse` (entity + provenance)
  - [ ] `SearchRequest` / `SearchResponse`
  - [ ] `EnrichmentStatusResponse`
- [ ] Create `models/provenance.py` — SourceRecord model
- [ ] Add input validation (address format, entity type enums)

**Acceptance Criteria:**
- All 12 entity types have Pydantic models
- All relationship types defined with property schemas
- Request/response models match API_SPEC.md
- Validation rejects malformed input with clear error messages

---

### Issue 2.3: Neo4j database driver and query layer
**Effort:** M
**Dependencies:** 1.4, 2.2
**Description:** Create the Neo4j connection pool and CRUD operations for entities and relationships.

**Sub-tasks:**
- [ ] Create `database/neo4j_driver.py` — async connection pool, session management
- [ ] Create entity CRUD operations (create, read, update, merge)
- [ ] Create relationship CRUD operations
- [ ] Create graph query methods:
  - [ ] Get full subgraph for an investigation (all entities + relationships)
  - [ ] Get entity with N-hop neighborhood
  - [ ] Full-text search across entities
  - [ ] Path finding between two entities
- [ ] Implement parameterized Cypher queries (prevent injection)
- [ ] Add connection health check

**Acceptance Criteria:**
- Can create, read, update entities in Neo4j
- Can create and query relationships
- Full-text search returns ranked results
- All queries use parameterized Cypher (no string interpolation)
- Connection pool handles concurrent requests

---

### Issue 2.4: PostgreSQL driver and provenance layer
**Effort:** S
**Dependencies:** 1.4, 2.2
**Description:** Create PostgreSQL connection and provenance tracking operations.

**Sub-tasks:**
- [ ] Create `database/postgres_client.py` — async connection pool (asyncpg)
- [ ] CRUD for `source_records` (provenance)
- [ ] CRUD for `investigations` (save/load)
- [ ] CRUD for `audit_log` (append-only)
- [ ] Query: get all provenance for an entity
- [ ] Query: get all entities from a specific source

**Acceptance Criteria:**
- Provenance records link to Neo4j entities by ID
- Audit log captures all investigation actions
- Queries return provenance sorted by confidence

---

### Issue 2.5: Investigation API endpoints
**Effort:** M
**Dependencies:** 2.3, 2.4
**Description:** Implement the core investigation lifecycle endpoints.

**Sub-tasks:**
- [ ] `POST /api/v1/investigation` — Accept address, create investigation, trigger enrichment
- [ ] `GET /api/v1/investigation/{id}` — Return full entity graph + metadata
- [ ] `GET /api/v1/entity/{id}` — Return single entity with provenance
- [ ] `POST /api/v1/entity/{id}/expand` — Load additional relationships (N+1 hop)
- [ ] `POST /api/v1/search` — Full-text search across all entities
- [ ] `POST /api/v1/investigation/{id}/save` — Save investigation with name/notes
- [ ] `GET /api/v1/saved-investigations` — List saved investigations
- [ ] `GET /api/v1/investigation/{id}/export` — Export as JSON or CSV

**Acceptance Criteria:**
- Creating investigation returns ID and triggers async enrichment
- Graph endpoint returns entities + relationships in format suitable for Vis.js
- Search returns ranked results with snippets
- Save/load round-trips correctly
- Export produces valid JSON/CSV

---

### Issue 2.6: Enrichment status and control endpoints
**Effort:** S
**Dependencies:** 2.5
**Description:** Endpoints for monitoring and controlling the enrichment pipeline.

**Sub-tasks:**
- [ ] `GET /api/v1/enrichment/status/{id}` — Return per-source status, progress, errors
- [ ] `POST /api/v1/enrichment/{id}/control` — Pause, resume, cancel enrichment
- [ ] `GET /api/v1/sources` — List all available connectors with health status
- [ ] `POST /api/v1/investigation/{id}/source/{source}/retry` — Retry a failed source

**Acceptance Criteria:**
- Status endpoint returns real-time progress per connector
- Pause/resume correctly halts/resumes background tasks
- Source list includes tier, auth requirements, health status

---

## Epic 3: Connector Framework & Tier 1 Sources

> Build the plugin-based connector system and implement all free API connectors.

### Issue 3.1: Abstract connector base class and registry
**Effort:** M
**Dependencies:** 2.2
**Description:** Create the connector framework that all data sources implement.

**Sub-tasks:**
- [ ] Create `connectors/base.py` — BaseConnector ABC with:
  - [ ] `discover(entity) -> list[Entity]`
  - [ ] `enrich(entity) -> dict`
  - [ ] `validate() -> bool`
  - [ ] `fetch(query) -> dict` (low-level API call)
  - [ ] Properties: name, tier, requires_auth, rate_limit, confidence_score
- [ ] Create `connectors/registry.py` — Auto-discover connectors from tier directories
- [ ] Create connector configuration schema (per-source settings)
- [ ] Create shared HTTP client (`utils/http_client.py`) with:
  - [ ] Async httpx with connection pooling
  - [ ] Automatic retry with exponential backoff
  - [ ] Response caching integration
  - [ ] User-Agent header management
  - [ ] Timeout configuration

**Acceptance Criteria:**
- New connectors discovered automatically when placed in tier directory
- Registry lists all available connectors with metadata
- HTTP client handles retries and timeouts gracefully
- Base class enforces interface contract

---

### Issue 3.2: Rate limiting engine
**Effort:** M
**Dependencies:** 3.1
**Description:** Implement rate limiting that respects per-source API limits.

**Sub-tasks:**
- [ ] Create `rate_limiting/limiter.py` — Token bucket algorithm per connector
- [ ] Create `rate_limiting/rate_limit_store.py` — Redis-backed tracking
- [ ] Parse rate limit headers from API responses (X-RateLimit-*, Retry-After)
- [ ] Implement queue-based request scheduling (FIFO per source)
- [ ] Create `rate_limiting/backoff_strategies.py` — Exponential, linear, jitter
- [ ] Circuit breaker: disable connector after N consecutive failures

**Acceptance Criteria:**
- Never exceeds configured rate limits per source
- Respects Retry-After headers
- Circuit breaker trips after 5 consecutive failures
- Circuit breaker resets after configurable cooldown
- Rate limit state persists in Redis across restarts

---

### Issue 3.3: Cache layer (Redis + offline)
**Effort:** M
**Dependencies:** 3.1
**Description:** Implement caching to reduce API calls and support offline mode.

**Sub-tasks:**
- [ ] Create `cache/redis_cache.py` — Redis-backed cache with TTL per source
- [ ] Create `cache/local_cache.py` — SQLite-based fallback for offline mode
- [ ] Create `cache/ttl_manager.py` — TTL configuration per connector
- [ ] Cache-aside pattern: check cache → API call → write cache
- [ ] Cache invalidation on manual refresh
- [ ] Cache stats endpoint (hit rate, size, oldest entry)

**Acceptance Criteria:**
- Repeated queries for same address don't re-call APIs within TTL
- Offline mode serves cached data when APIs are unreachable
- TTL is configurable per connector (e.g., Census = 30 days, crime = 1 day)
- Cache can be cleared per source or globally

---

### Issue 3.4: Connector — Census Geocoder
**Effort:** S
**Dependencies:** 3.1
**Description:** Geocode addresses to lat/long + census tract/block.

**Sub-tasks:**
- [ ] Implement `tier1/census_geocoder.py`
- [ ] Input: address string → Output: lat, long, state FIPS, county FIPS, tract, block
- [ ] Handle batch geocoding (up to 10,000 addresses)
- [ ] Normalize address format before sending
- [ ] Unit tests with mock responses
- [ ] Integration test against live API

**Acceptance Criteria:**
- Geocodes a Gwinnett County address to correct coordinates
- Returns census tract and block identifiers
- Handles invalid/ambiguous addresses gracefully
- Works without authentication

---

### Issue 3.5: Connector — Census Data API
**Effort:** S
**Dependencies:** 3.4
**Description:** Fetch demographics, income, housing data for a census tract.

**Sub-tasks:**
- [ ] Implement `tier1/census_data.py`
- [ ] Query ACS 5-year estimates by tract
- [ ] Fields: population, median income, age distribution, housing units, owner-occupied %, poverty rate
- [ ] Map tract from geocoder output to census data query
- [ ] Create CENSUS_TRACT entity from results
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Returns demographic data for any Georgia census tract
- Creates properly typed CensusTract entity
- Handles missing/suppressed census data gracefully

---

### Issue 3.6: Connector — FBI Crime Data API
**Effort:** S
**Dependencies:** 3.1
**Description:** Fetch crime statistics for the county/city where the address is located.

**Sub-tasks:**
- [ ] Implement `tier1/fbi_crime.py`
- [ ] Query by ORI (agency identifier) or state/county
- [ ] Fields: violent crime, property crime, arson by year
- [ ] Create CRIME_RECORD summary entities
- [ ] Create ADDRESS --[HAS_CRIME_NEAR]--> CRIME_RECORD relationships
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Returns crime stats for Gwinnett County
- Data is broken down by crime type and year
- Handles years with no data gracefully

---

### Issue 3.7: Connector — EPA ECHO
**Effort:** S
**Dependencies:** 3.4
**Description:** Find nearby environmental facilities, violations, and enforcement actions.

**Sub-tasks:**
- [ ] Implement `tier1/epa_echo.py`
- [ ] Query facilities within radius of geocoded address
- [ ] Fields: facility name, type, violations, penalties, compliance status
- [ ] Create ENVIRONMENTAL_FACILITY entities
- [ ] Create ADDRESS --[HAS_ENV_FACILITY]--> ENVIRONMENTAL_FACILITY relationships
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Finds EPA-regulated facilities near a Gwinnett County address
- Returns violation history and compliance status
- Configurable search radius (default 1 mile)

---

### Issue 3.8: Connector — SEC EDGAR
**Effort:** M
**Dependencies:** 3.1
**Description:** Search SEC filings for businesses and officers linked to the address.

**Sub-tasks:**
- [ ] Implement `tier1/sec_edgar.py`
- [ ] Full-text search by company name and person name
- [ ] Query submissions by CIK (Central Index Key)
- [ ] Extract officer names, business addresses from filings
- [ ] Create BUSINESS and PERSON entities from filing data
- [ ] Create PERSON --[OWNS_BUSINESS]--> BUSINESS relationships
- [ ] Set proper User-Agent header (SEC requirement)
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Finds SEC-registered entities by name or address
- Extracts officer/director names from filings
- Respects SEC's 10 requests/second limit
- User-Agent header identifies the application

---

### Issue 3.9: Connector — CourtListener
**Effort:** M
**Dependencies:** 3.1
**Description:** Search federal/state court records for cases involving discovered entities.

**Sub-tasks:**
- [ ] Implement `tier1/courtlistener.py`
- [ ] Search by party name (person or business)
- [ ] Fields: case number, court, case type, filing date, disposition, parties
- [ ] Create CASE entities
- [ ] Create PERSON --[NAMED_IN_CASE]--> CASE relationships
- [ ] Support RECAP archive for PACER documents
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Finds federal court cases by party name
- Returns docket entries and case metadata
- Handles pagination for parties with many cases
- Links cases to correct person/business entities

---

### Issue 3.10: Connector — OpenFEMA
**Effort:** S
**Dependencies:** 3.4
**Description:** Fetch disaster declarations and flood insurance data for the address area.

**Sub-tasks:**
- [ ] Implement `tier1/openfema.py`
- [ ] Query disaster declarations by state/county
- [ ] Query NFIP flood claims by zip code
- [ ] Add flood risk data to ADDRESS entity properties
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Returns disaster history for Gwinnett County
- Returns flood zone designation for address
- Creates risk indicators on address entity

---

### Issue 3.11: Connector — OSM Nominatim
**Effort:** S
**Dependencies:** 3.1
**Description:** Backup geocoder and address validation via OpenStreetMap.

**Sub-tasks:**
- [ ] Implement `tier1/nominatim.py`
- [ ] Forward geocoding (address → coordinates)
- [ ] Reverse geocoding (coordinates → address)
- [ ] Respect 1 request/second rate limit
- [ ] Set proper User-Agent header
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Geocodes addresses when Census Geocoder is unavailable
- Respects 1 req/sec rate limit strictly
- Returns structured address components

---

### Issue 3.12: Connector — NHTSA vPIC
**Effort:** S
**Dependencies:** 3.1
**Description:** Decode VINs to vehicle details and check recalls.

**Sub-tasks:**
- [ ] Implement `tier1/nhtsa_vpic.py`
- [ ] VIN decode → make, model, year, body type, vehicle class
- [ ] Recall lookup by VIN
- [ ] Create VEHICLE entities
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Decodes valid VINs to full vehicle specifications
- Returns active recalls for a vehicle
- Handles invalid VINs gracefully

---

## Epic 4: Enrichment Pipeline

> Build the orchestration engine that chains connectors together for automated discovery.

### Issue 4.1: Enrichment orchestrator
**Effort:** L
**Dependencies:** 3.1, 3.2, 3.3
**Description:** Build the async pipeline that coordinates connector execution for an investigation.

**Sub-tasks:**
- [ ] Create `enrichment/orchestrator.py`
- [ ] Define enrichment phases (geocoding → address enrichment → discovery → person enrichment → linking)
- [ ] Parallel execution within phases using asyncio.gather
- [ ] Sequential execution between phases (each phase depends on prior)
- [ ] Track per-connector status (pending, running, complete, failed, rate_limited)
- [ ] Celery task integration for background processing
- [ ] WebSocket or polling for real-time status updates
- [ ] Configurable: select which sources to use, max depth, timeout

**Acceptance Criteria:**
- Submitting an address triggers full enrichment pipeline
- Tier 1 connectors run in parallel within each phase
- Status is queryable in real-time
- Pipeline is resumable after pause
- Timeout kills long-running enrichments
- Errors in one connector don't block others

---

### Issue 4.2: Entity discovery algorithm
**Effort:** M
**Dependencies:** 4.1
**Description:** Recursive algorithm that discovers new entities from existing ones up to N hops.

**Sub-tasks:**
- [ ] Create `enrichment/discovery.py`
- [ ] Implement recursive discovery with depth limit (default 3)
- [ ] Visited set to prevent cycles
- [ ] Priority queue: enrich high-confidence entities first
- [ ] Discovery rules:
  - [ ] ADDRESS → discover PERSONs (property records, people search)
  - [ ] ADDRESS → discover BUSINESSes (SOS, SEC)
  - [ ] PERSON → discover relatives, employers, court cases
  - [ ] BUSINESS → discover officers, filings, related businesses
- [ ] Configurable max entities per investigation (default 500)

**Acceptance Criteria:**
- Starting from one address, discovers residents and businesses
- Each discovered entity triggers further enrichment
- Respects depth limit and max entity count
- No infinite loops or duplicate discoveries

---

### Issue 4.3: Entity deduplication and merging
**Effort:** M
**Dependencies:** 4.2
**Description:** Detect and merge duplicate entities from different sources.

**Sub-tasks:**
- [ ] Create `enrichment/deduplicator.py`
- [ ] Fuzzy name matching for PERSONs (Levenshtein distance, phonetic matching)
- [ ] Address normalization and matching
- [ ] Business name normalization (strip Inc, LLC, etc.)
- [ ] Confidence-weighted merge: keep highest confidence attributes
- [ ] Create merge audit trail (which entities were merged, from which sources)
- [ ] Unit tests with known duplicate scenarios

**Acceptance Criteria:**
- "John Doe" and "JOHN A DOE" at same address merge into one entity
- "Acme Inc" and "ACME, INC." merge into one business
- Merge preserves all source attributions
- Audit trail shows merge history

---

### Issue 4.4: Conflict resolution
**Effort:** S
**Dependencies:** 4.3
**Description:** Handle contradictory data from multiple sources.

**Sub-tasks:**
- [ ] Create `enrichment/conflict_resolver.py`
- [ ] Strategy: confidence-weighted voting (highest confidence wins)
- [ ] Strategy: newest-wins (most recent retrieval date)
- [ ] Strategy: source-priority (government sources > commercial)
- [ ] Flag conflicts for user review
- [ ] Store all values with provenance (don't discard losing values)

**Acceptance Criteria:**
- When two sources disagree on an attribute, highest confidence wins
- All conflicting values are preserved in provenance
- Conflicts are flagged in entity detail view

---

### Issue 4.5: Address validation and normalization
**Effort:** S
**Dependencies:** 3.4
**Description:** Normalize and validate address input before enrichment.

**Sub-tasks:**
- [ ] Create `validation/address_validator.py`
- [ ] Parse address components (street, city, state, zip)
- [ ] Normalize abbreviations (St → Street, Ave → Avenue, GA → Georgia)
- [ ] Validate state/zip combinations
- [ ] Standardize to USPS format
- [ ] Handle apartment/unit numbers

**Acceptance Criteria:**
- "123 main st, lawrenceville ga 30043" normalizes to "123 Main Street, Lawrenceville, GA 30043"
- Invalid addresses return clear validation errors
- Supports common address variations

---

## Epic 5: Frontend - Core UI

> Build the React application with address input, graph visualization, and entity panels.

### Issue 5.1: React application scaffold
**Effort:** S
**Dependencies:** 1.1
**Description:** Set up the React app with routing, layout, and design system.

**Sub-tasks:**
- [ ] Initialize Vite + React + TypeScript project
- [ ] Install and configure TailwindCSS + shadcn/ui
- [ ] Set up React Router with pages: Home, Graph, Search
- [ ] Create Layout components (Header, Sidebar, main content area)
- [ ] Create API client module (axios/fetch with base URL config)
- [ ] Set up Zustand stores (app state, graph state, enrichment state)
- [ ] Configure TanStack Query for server state

**Acceptance Criteria:**
- App renders with header, sidebar, and content area
- Routing works between pages
- API client configured to hit backend
- Design system tokens (colors, typography, spacing) applied

---

### Issue 5.2: Address input form
**Effort:** M
**Dependencies:** 5.1
**Description:** Build the primary address input interface with autocomplete.

**Sub-tasks:**
- [ ] Create `AddressForm.tsx` — street, city, state, zip fields
- [ ] Address autocomplete integration (Google Places or Nominatim)
- [ ] Form validation (required fields, format checks)
- [ ] Submit triggers investigation creation via API
- [ ] Loading state during submission
- [ ] Recent searches list (stored in localStorage)
- [ ] Saved investigations list (from API)
- [ ] Error handling for invalid addresses

**Acceptance Criteria:**
- User can type an address and get autocomplete suggestions
- Submitting a valid address navigates to graph view
- Invalid addresses show inline validation errors
- Recent searches persist across sessions

---

### Issue 5.3: Graph visualization component
**Effort:** XL
**Dependencies:** 5.1, 2.5
**Description:** Build the interactive relationship graph using Vis.js/Neovis.js. This is the primary UI component.

**Sub-tasks:**
- [ ] Create `GraphVisualization.tsx` — main canvas component
- [ ] Integrate Vis.js Network with force-directed layout
- [ ] Entity type styling (10 types with distinct colors, shapes, icons per DESIGN_SYSTEM.md)
  - [ ] Person = blue circle
  - [ ] Address = red house icon
  - [ ] Business = green diamond
  - [ ] Property = amber square
  - [ ] Case = purple gavel
  - [ ] Vehicle = pink car
  - [ ] Crime = dark red triangle
  - [ ] Social = teal circle
  - [ ] Phone/Email = gray small circle
  - [ ] Census/Env = slate hexagon
- [ ] Relationship edge styling (labeled, directional arrows, color by type)
- [ ] Node sizing by importance (number of connections)
- [ ] Create `GraphControls.tsx` — zoom, fit, reset, layout toggle
- [ ] Click handler: select node → show entity detail panel
- [ ] Double-click handler: expand node (load more relationships)
- [ ] Hover handler: highlight connected nodes and edges
- [ ] Create `NodeContextMenu.tsx` — right-click menu:
  - [ ] Expand connections
  - [ ] Hide node
  - [ ] Pin/unpin position
  - [ ] View details
  - [ ] Search related
- [ ] Create `RelationshipFilter.tsx` — toggle relationship types on/off
- [ ] Create `EntityTypeFilter.tsx` — toggle entity types on/off
- [ ] Minimap for large graphs
- [ ] Export graph as PNG

**Acceptance Criteria:**
- Graph renders entities and relationships from API data
- Each entity type has distinct visual appearance
- Click, double-click, hover, right-click interactions work
- Graph is performant with 200+ nodes
- Filtering by entity/relationship type works in real-time
- Graph layout is visually clean (no overlapping nodes)

---

### Issue 5.4: Entity detail panel
**Effort:** M
**Dependencies:** 5.3
**Description:** Slide-out panel showing all data about a selected entity.

**Sub-tasks:**
- [ ] Create `EntityDetailPanel.tsx` — slide-out from right side
- [ ] Tab structure: Overview, Relationships, Timeline, Sources
- [ ] Overview tab: all known attributes in structured layout
- [ ] Relationships tab: list of connected entities with types
- [ ] Timeline tab: chronological events (when data was discovered, relationship dates)
- [ ] Sources tab: provenance for each attribute (which connector, confidence, date)
- [ ] Create entity-type-specific cards:
  - [ ] `PersonCard.tsx` — name, DOB, aliases, addresses, phones, emails
  - [ ] `AddressCard.tsx` — full address, coordinates, property info, demographics
  - [ ] `BusinessCard.tsx` — name, type, officers, filings, addresses
  - [ ] `CaseCard.tsx` — case number, court, parties, disposition
  - [ ] `PropertyCard.tsx` — value, zoning, year built, tax history
- [ ] "Enrich" button: trigger deeper search for this entity
- [ ] "Expand" button: load more relationships into graph
- [ ] Copy data to clipboard
- [ ] Link to raw source (external URL)

**Acceptance Criteria:**
- Clicking a graph node opens the detail panel
- Panel shows correct data for each entity type
- Provenance shows source attribution for every fact
- Enrich button triggers API call and updates graph
- Panel closes on clicking elsewhere or pressing Escape

---

### Issue 5.5: Enrichment status bar
**Effort:** S
**Dependencies:** 5.1, 2.6
**Description:** Real-time display of enrichment pipeline progress.

**Sub-tasks:**
- [ ] Create `EnrichmentStatusBar.tsx` — bottom bar or sidebar section
- [ ] Poll `GET /api/v1/enrichment/status/{id}` every 2-3 seconds
- [ ] Per-source status indicators (querying, complete, failed, rate limited)
- [ ] Overall progress bar (completed sources / total sources)
- [ ] Entity count (discovered so far)
- [ ] Error messages with retry buttons
- [ ] Pause/resume/cancel controls
- [ ] Stop polling when enrichment is complete

**Acceptance Criteria:**
- Shows real-time progress of all data sources
- Failed sources show error message and retry button
- Progress updates without page refresh
- Pause/resume correctly controls backend pipeline

---

### Issue 5.6: Search and filter interface
**Effort:** M
**Dependencies:** 5.1, 2.5
**Description:** Full-text search across all entities within an investigation.

**Sub-tasks:**
- [ ] Create `SearchBox.tsx` — search input in header
- [ ] Debounced search (300ms) calling `POST /api/v1/search`
- [ ] Create `SearchResults.tsx` — ranked list of matching entities
- [ ] Result cards show entity type, name, snippet, confidence
- [ ] Click result → navigate to entity in graph (center + highlight)
- [ ] Create `FilterPanel.tsx` — filter by entity type, date range, confidence threshold
- [ ] Search within current investigation or globally

**Acceptance Criteria:**
- Search returns results within 500ms
- Results are ranked by relevance
- Clicking a result centers the graph on that entity
- Filters narrow results in real-time

---

### Issue 5.7: Investigation save/load
**Effort:** S
**Dependencies:** 5.1, 2.5
**Description:** Save and reload investigations.

**Sub-tasks:**
- [ ] Create save dialog (name, notes)
- [ ] Create saved investigations list page
- [ ] Load saved investigation → restore graph state
- [ ] Delete saved investigation with confirmation
- [ ] Show last updated timestamp
- [ ] Export investigation as JSON file

**Acceptance Criteria:**
- Saved investigation restores exact graph state
- List shows all saved investigations with timestamps
- Delete requires confirmation
- JSON export is valid and re-importable

---

## Epic 6: Tier 2 Connectors (Gwinnett County)

> Implement scrapers for county-specific data sources.

### Issue 6.1: Connector — Gwinnett County ArcGIS (Parcels)
**Effort:** M
**Dependencies:** 3.1, 3.4
**Description:** Query Gwinnett County parcel data via ArcGIS REST API.

**Sub-tasks:**
- [ ] Implement `tier2/gwinnett_parcel.py`
- [ ] Query parcels by address or coordinates
- [ ] Fields: parcel ID, owner, zoning, land use, acreage
- [ ] Create PROPERTY entities and PERSON --[OWNS_PROPERTY]--> PROPERTY relationships
- [ ] Handle ArcGIS pagination (1000 features per request)
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Returns parcel data for Gwinnett County addresses
- Owner name extracted and linked as PERSON entity
- Handles addresses with multiple parcels

---

### Issue 6.2: Connector — GA Secretary of State (Business Search)
**Effort:** M
**Dependencies:** 3.1
**Description:** Search Georgia business registrations by name, officer, or registered agent.

**Sub-tasks:**
- [ ] Implement `tier2/ga_secretary_state.py`
- [ ] Web scraping of ecorp.sos.ga.gov (no API available)
- [ ] Search by entity name, officer name, registered agent
- [ ] Extract: entity name, type, status, formation date, registered agent, officers
- [ ] Create BUSINESS entities
- [ ] Create PERSON --[OWNS_BUSINESS]--> BUSINESS relationships for officers
- [ ] Respect robots.txt and rate limit (2 req/sec max)
- [ ] Unit tests with mock HTML responses

**Acceptance Criteria:**
- Finds businesses registered in Georgia by name or officer
- Extracts officer/agent names and creates person entities
- Handles pagination of search results
- Respects robots.txt

---

### Issue 6.3: Connector — Gwinnett Courts (Case Search)
**Effort:** M
**Dependencies:** 3.1
**Description:** Search Gwinnett County court records by name or case number.

**Sub-tasks:**
- [ ] Implement `tier2/gwinnett_courts.py`
- [ ] Web scraping of gwinnettcourts.com/casesearch/
- [ ] Search by name or case number
- [ ] Extract: case number, type, parties, filing date, status, charges, disposition
- [ ] Create CASE entities
- [ ] Create PERSON --[NAMED_IN_CASE]--> CASE relationships
- [ ] Handle multiple case types (civil, criminal, traffic)
- [ ] Unit tests with mock HTML responses

**Acceptance Criteria:**
- Finds court cases by party name
- Extracts all parties and creates relationships
- Distinguishes civil vs criminal cases
- Handles no-results gracefully

---

### Issue 6.4: Connector — qPublic (Property Details)
**Effort:** M
**Dependencies:** 3.1
**Description:** Scrape detailed property information from qPublic for Gwinnett County.

**Sub-tasks:**
- [ ] Implement `tier2/qpublic.py`
- [ ] Search by address or owner name
- [ ] Extract: owner, sale history, assessed value, building details (sqft, bedrooms, year built), land use
- [ ] Enrich existing PROPERTY entities with detailed attributes
- [ ] Extract sale history for timeline
- [ ] Unit tests with mock HTML responses

**Acceptance Criteria:**
- Returns detailed property data for Gwinnett addresses
- Sale history creates timeline entries
- Building characteristics enriched on property entity

---

### Issue 6.5: Connector — GSCCCA (Deeds, Liens, UCC)
**Effort:** M
**Dependencies:** 3.1
**Description:** Search Georgia deed records and UCC filings.

**Sub-tasks:**
- [ ] Implement `tier2/gsccca_deeds.py`
- [ ] Search real estate records by name or property
- [ ] Search UCC filings by name
- [ ] Extract: grantor/grantee, instrument type, recording date, lien amounts
- [ ] Create relationships: PERSON --[OWNS_PROPERTY]--> PROPERTY (via deed)
- [ ] Flag liens and encumbrances on property entities
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Finds deed records in Gwinnett County
- Extracts grantor/grantee and creates person entities
- UCC filings linked to business entities
- Liens flagged on property entities

---

### Issue 6.6: Connector — GBI Sex Offender Registry
**Effort:** S
**Dependencies:** 3.1
**Description:** Check Georgia sex offender registry for addresses and names.

**Sub-tasks:**
- [ ] Implement `tier2/gbi_sex_offender.py`
- [ ] Search by address/zip or name
- [ ] Extract: name, address, offense details, registration status, photo URL
- [ ] Create CRIME_RECORD entities for offenses
- [ ] Create PERSON --[NAMED_IN_CASE]--> CRIME_RECORD relationships
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Finds registered sex offenders near an address
- Creates proper person and crime record entities
- Handles no-results gracefully

---

### Issue 6.7: Connector — Gwinnett Sheriff JAIL View
**Effort:** S
**Dependencies:** 3.1
**Description:** Search current/recent inmate records in Gwinnett County.

**Sub-tasks:**
- [ ] Implement `tier2/gwinnett_sheriff_jail.py`
- [ ] Search by name
- [ ] Extract: booking date, charges, bond amount, status, age, address
- [ ] Create PERSON entities and CASE entities
- [ ] Unit tests with mock responses

**Acceptance Criteria:**
- Finds current/recent inmates by name
- Extracts charges and creates case entities
- Links to person entities

---

## Epic 7: Tier 3 Connectors & Advanced Features

> Implement limited-free-tier connectors and advanced UI features.

### Issue 7.1: Connector — OpenCorporates
**Effort:** S
**Dependencies:** 3.1
**Description:** Search global company registry via OpenCorporates API.

**Sub-tasks:**
- [ ] Implement `tier3/opencorporates.py`
- [ ] Search by company name, officer name, registered address
- [ ] Extract: company name, jurisdiction, status, officers, filings
- [ ] Create BUSINESS entities with cross-jurisdictional links
- [ ] Respect free tier limits

**Acceptance Criteria:**
- Finds companies registered in Georgia and beyond
- Links officers to person entities
- Handles API rate limits gracefully

---

### Issue 7.2: Connector — Google Places
**Effort:** S
**Dependencies:** 3.1
**Description:** Enrich addresses with nearby business/POI data from Google Places.

**Sub-tasks:**
- [ ] Implement `tier3/google_places.py`
- [ ] Nearby search by coordinates
- [ ] Extract: business name, type, address, rating, hours
- [ ] Create BUSINESS entities for nearby places
- [ ] Stay within free tier (~10K calls/month)

**Acceptance Criteria:**
- Returns nearby businesses and points of interest
- Creates business entities linked to address
- Tracks API usage against monthly quota

---

### Issue 7.3: Connector — Hunter.io (Email Lookup)
**Effort:** S
**Dependencies:** 3.1
**Description:** Find email addresses associated with domains/companies found at an address.

**Sub-tasks:**
- [ ] Implement `tier3/hunter_io.py`
- [ ] Domain search: find emails for a company domain
- [ ] Email verification: validate discovered emails
- [ ] Create EMAIL_ADDRESS entities
- [ ] Create PERSON --[HAS_EMAIL]--> EMAIL_ADDRESS relationships
- [ ] Stay within free tier (25 searches/month)

**Acceptance Criteria:**
- Finds emails for business domains
- Creates email entities linked to persons
- Tracks usage against monthly quota

---

### Issue 7.4: Connector — NumVerify (Phone Validation)
**Effort:** S
**Dependencies:** 3.1
**Description:** Validate and enrich phone numbers found during investigation.

**Sub-tasks:**
- [ ] Implement `tier3/numverify.py`
- [ ] Validate phone numbers (carrier, line type, location)
- [ ] Create PHONE_NUMBER entities
- [ ] Create PERSON --[HAS_PHONE]--> PHONE_NUMBER relationships
- [ ] Stay within free tier (100 requests/month)

**Acceptance Criteria:**
- Validates phone numbers with carrier and line type
- Creates phone entities linked to persons
- Tracks usage against monthly quota

---

### Issue 7.5: Timeline slider for graph
**Effort:** M
**Dependencies:** 5.3
**Description:** Add a timeline slider to the graph view that filters entities/relationships by date.

**Sub-tasks:**
- [ ] Create `TimelineSlider.tsx` — range slider below graph
- [ ] Filter graph nodes/edges by relationship establishment dates
- [ ] Animate graph changes as slider moves
- [ ] Show event markers on timeline (court filings, property sales, etc.)
- [ ] Play/pause animation

**Acceptance Criteria:**
- Slider filters graph to show only entities active at selected time
- Smooth animation when sliding through time
- Event markers visible on timeline

---

### Issue 7.6: Map view integration
**Effort:** M
**Dependencies:** 5.1, 3.4
**Description:** Add a map view showing the address and nearby points of interest.

**Sub-tasks:**
- [ ] Create `MapView.tsx` using Leaflet + OpenStreetMap
- [ ] Show primary address marker
- [ ] Show nearby facilities (EPA, businesses, crime incidents) as markers
- [ ] Click marker → show entity detail
- [ ] Toggle between graph view and map view
- [ ] Configurable radius for nearby entities

**Acceptance Criteria:**
- Map centers on investigation address
- Nearby entities shown as typed markers
- Click marker shows entity detail panel
- Smooth toggle between graph and map views

---

### Issue 7.7: Investigation audit log
**Effort:** S
**Dependencies:** 2.4, 5.1
**Description:** Track and display all actions taken during an investigation.

**Sub-tasks:**
- [ ] Log all actions: search, enrich, expand, save, export
- [ ] Create `AuditLog.tsx` — scrollable log in sidebar
- [ ] Show timestamp, action type, entity involved
- [ ] Persist to PostgreSQL audit_log table
- [ ] Export audit log as CSV

**Acceptance Criteria:**
- Every investigation action is logged
- Audit log is visible in UI
- Log persists across sessions
- Exportable for compliance

---

### Issue 7.8: Dark mode
**Effort:** S
**Dependencies:** 5.1
**Description:** Add dark mode theme toggle.

**Sub-tasks:**
- [ ] Create dark mode color tokens in TailwindCSS
- [ ] Theme toggle in header
- [ ] Graph visualization adapts to dark mode
- [ ] Persist preference in localStorage

**Acceptance Criteria:**
- Toggle switches all UI elements to dark theme
- Graph colors remain distinguishable in dark mode
- Preference persists across sessions

---

## Dependency Graph

```
Epic 1 (Foundation)
├── 1.1 Monorepo ──────────────────────┐
│   ├── 1.2 Docker Compose             │
│   │   └── 1.4 DB Schema              │
│   └── 1.3 CI/CD                      │
│                                      │
Epic 2 (Backend API)                   │
├── 2.1 FastAPI Scaffold ◄─────────── 1.1
│   └── 2.2 Pydantic Models            │
│       ├── 2.3 Neo4j Driver ◄──────── 1.4
│       ├── 2.4 Postgres Driver ◄───── 1.4
│       └── 2.5 Investigation API ◄─── 2.3, 2.4
│           └── 2.6 Enrichment API      │
│                                      │
Epic 3 (Connectors)                    │
├── 3.1 Base + Registry ◄──────────── 2.2
│   ├── 3.2 Rate Limiting              │
│   ├── 3.3 Cache Layer                │
│   ├── 3.4 Census Geocoder            │
│   │   ├── 3.5 Census Data            │
│   │   ├── 3.7 EPA ECHO              │
│   │   └── 3.10 OpenFEMA             │
│   ├── 3.6 FBI Crime                  │
│   ├── 3.8 SEC EDGAR                  │
│   ├── 3.9 CourtListener             │
│   ├── 3.11 Nominatim                │
│   └── 3.12 NHTSA vPIC               │
│                                      │
Epic 4 (Pipeline)                      │
├── 4.1 Orchestrator ◄──────────────── 3.1, 3.2, 3.3
│   ├── 4.2 Discovery Algorithm        │
│   │   ├── 4.3 Deduplication         │
│   │   │   └── 4.4 Conflict Resolution│
│   └── 4.5 Address Validation ◄────── 3.4
│                                      │
Epic 5 (Frontend)                      │
├── 5.1 React Scaffold ◄──────────── 1.1
│   ├── 5.2 Address Form               │
│   ├── 5.3 Graph Visualization ◄───── 2.5
│   │   └── 5.4 Entity Detail Panel    │
│   ├── 5.5 Enrichment Status ◄─────── 2.6
│   ├── 5.6 Search & Filter ◄──────── 2.5
│   └── 5.7 Save/Load                 │
│                                      │
Epic 6 (Tier 2 Connectors)            │
├── 6.1-6.7 ◄─────────────────────── 3.1, 3.4
│                                      │
Epic 7 (Advanced)                      │
├── 7.1-7.4 Tier 3 Connectors ◄────── 3.1
├── 7.5 Timeline ◄─────────────────── 5.3
├── 7.6 Map View ◄─────────────────── 5.1, 3.4
├── 7.7 Audit Log ◄────────────────── 2.4, 5.1
└── 7.8 Dark Mode ◄────────────────── 5.1
```

---

## Suggested Implementation Order

### Phase 1: Walking Skeleton (Issues: 1.1, 1.2, 1.3, 2.1, 5.1)
Get the full stack running end-to-end with placeholder data.

### Phase 2: Core Backend (Issues: 1.4, 2.2, 2.3, 2.4, 2.5, 2.6)
Build the API layer with real database operations.

### Phase 3: First Connectors (Issues: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 4.5)
Connector framework + Census + FBI — enough to demonstrate the pipeline.

### Phase 4: Graph UI (Issues: 5.2, 5.3, 5.4, 5.5)
Build the graph visualization — the core user experience.

### Phase 5: Enrichment Pipeline (Issues: 4.1, 4.2, 4.3, 4.4)
Wire connectors together with automated discovery.

### Phase 6: Remaining Tier 1 (Issues: 3.7, 3.8, 3.9, 3.10, 3.11, 3.12)
Complete all free API connectors.

### Phase 7: Search & Polish (Issues: 5.6, 5.7, 7.7, 7.8)
Search, save/load, audit logging, dark mode.

### Phase 8: County Scrapers (Issues: 6.1-6.7)
Gwinnett County specific data sources.

### Phase 9: Advanced (Issues: 7.1-7.6)
Tier 3 connectors, timeline, map view.

---

## Effort Summary

| Epic | Issues | Total Effort |
|------|--------|-------------|
| 1. Foundation | 4 | S + M + S + M = ~2 weeks |
| 2. Backend API | 6 | S + M + M + S + M + S = ~3 weeks |
| 3. Tier 1 Connectors | 12 | M + M + M + S + S + S + S + M + M + S + S + S = ~4 weeks |
| 4. Pipeline | 5 | L + M + M + S + S = ~3 weeks |
| 5. Frontend | 7 | S + M + XL + M + S + M + S = ~4 weeks |
| 6. Tier 2 Connectors | 7 | M + M + M + M + M + S + S = ~3 weeks |
| 7. Advanced | 8 | S + S + S + S + M + M + S + S = ~2 weeks |
| **Total** | **49** | **~21 weeks** |
