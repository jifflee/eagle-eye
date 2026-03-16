# Eagle Eye: Complete Product Specification

**Version:** 1.0
**Date:** 2026-03-16
**Status:** Ready for Architecture & Development
**Tech Stack:** React + Neovis.js/Vis.js, TailwindCSS + shadcn/ui, FastAPI, Neo4j

---

## 1. EXECUTIVE SUMMARY

**Eagle Eye** is a modern OSINT intelligence platform that takes a single address and builds a comprehensive intelligence profile through relationship graph visualization. Analysts submit an address, the system queries 30+ public data sources (Census, FBI, EPA, SEC, courts, property records, etc.), and presents findings as an interactive relationship graph where entities (people, businesses, properties, court cases, vehicles) and their connections are visually mapped for rapid analysis and discovery.

### Core Value Proposition
- **Speed**: From address to enriched graph in <30 seconds
- **Relationships**: Uncover hidden connections between entities through force-directed visualization
- **Transparency**: Full data provenance and source attribution for every fact
- **Exploration**: Intuitive graph interaction enables analyst-driven discovery, not pre-defined workflows

### MVP Scope
- Address search with autocomplete
- Full graph construction (address + 3-hop relationships)
- Interactive force-directed graph with entity clustering
- Entity detail panels with source attribution
- Data source status tracking
- Basic filtering and search
- Timeline slider for temporal analysis
- Graph export (image/JSON)

### Future Features (Post-MVP)
- Collaboration & team sharing
- Saved investigations & templates
- Advanced analytics (centrality, community detection, pattern matching)
- Historical state versioning
- Bulk address import
- Custom data source connectors
- Mobile/tablet optimization

---

## 2. PROBLEM STATEMENT

### Current Pain Points
Intelligence analysts (LE, corporate security, journalists) investigating addresses must:
1. Manually visit 10+ separate databases and websites
2. Cross-reference data points manually (property records → tax records → court cases → people)
3. Spend hours correlating data across sources with no unified view
4. Lose context when switching between tabs/systems
5. Have no visual way to discover hidden relationships

### The Gap
Existing tools are either:
- **Siloed**: Single-purpose databases (county property records, FBI, etc.)
- **Expensive**: Enterprise OSINT platforms (Palantir) cost $100k+/year
- **Non-visual**: Text-based reports don't reveal relationship patterns
- **Manual**: Require analysts to drive all discovery logic

### What Eagle Eye Solves
A unified, visual platform that:
- Automatically queries all relevant public sources for a single address
- Constructs a relationship graph in seconds
- Reveals hidden connections at a glance
- Costs $0 (open source) or $X/month (SaaS)
- Works for civic researchers, journalists, law enforcement, and corporate investigators

---

## 3. GOALS & NON-GOALS

### Goals (In Scope)
- Enable analysts to investigate any US address and discover relationships in <1 minute
- Provide complete data provenance (source, date collected, confidence) for every entity & relationship
- Visualize up to 500 entities with interactive graph layout
- Support 3-hop relationship exploration with manual expansion
- Integrate 30+ public OSINT sources via modular connector system
- Enable analysts to save, re-open, and export investigations
- Track data source query status and retry failures

### Non-Goals (Out of Scope for MVP)
- Real-time data (all data is refreshed daily max)
- Multi-user collaboration or team features
- PII redaction or privacy controls (all data is public; legal/compliance is user's responsibility)
- Mobile or tablet optimization (desktop-first)
- Predictive analytics or ML-based pattern detection
- Custom source connectors (fixed set of 30 sources only)
- API rate-limit management for end users
- Historical state versioning
- Bulk/batch address imports

---

## 4. TARGET USERS & PERSONAS

### Primary Personas

#### 4.1 Local Law Enforcement Analyst
- **Name:** Detective Maria Chen
- **Background:** 5 years in property crimes unit, comfortable with databases
- **Goal:** Quickly establish connections between a suspect address and associates
- **Usage:** 5–10 investigations/week, 30 min–2 hour depth
- **Pain Point:** Currently spends 2 hours gathering data; wants it in 15 minutes
- **Success Metric:** "I can see all associates of a suspect address in one place"

#### 4.2 Investigative Journalist
- **Name:** James Rodriguez
- **Background:** 10 years reporting on corruption, self-taught on tools
- **Goal:** Build a narrative around an address; find connected entities for follow-up reporting
- **Usage:** 3–5 deep investigations/month, 5+ hours depth
- **Pain Point:** Switching between 15+ websites; can't visualize relationship complexity
- **Success Metric:** "I discovered a connection I wouldn't have found manually"

#### 4.3 Corporate Security Investigator
- **Name:** Priya Patel
- **Background:** Ex-military background, forensic accounting experience
- **Goal:** Due diligence on properties, associates before acquisition or partnership
- **Usage:** 2–3 investigations/week, 1–3 hours depth
- **Pain Point:** Inconsistent data sources; hard to share findings with legal team
- **Success Metric:** "I found a compliance risk that would have been missed"

#### 4.4 Civic Researcher / Data Journalist
- **Name:** Alex Kim
- **Background:** Academic researcher, familiar with datasets, non-technical
- **Goal:** Understand real estate ownership patterns, policy impact on neighborhoods
- **Usage:** Episodic, 20+ hours for major research project
- **Pain Point:** No tools exist to explore geographic + ownership relationships
- **Success Metric:** "I can generate insights about property ownership networks"

### User Skill Levels
- **Technical sophistication:** Low–Medium (comfortable with web apps, databases; not developers)
- **Domain knowledge:** Medium–High (understand their investigation domain; may be new to OSINT)
- **Graph literacy:** Low (no previous exposure to relationship visualization; needs UX guidance)

---

## 5. FUNCTIONAL REQUIREMENTS

### 5.1 Address Input & Search

#### 5.1.1 Address Autocomplete
- **Input field** accepts free-text address entry
- **Real-time autocomplete** returns 5–10 matching US addresses (prioritize Georgia/Gwinnett initially, then expand nationally)
- **Data source:** Google Maps API / USPS Address API
- **Display format:** `Street, City, State ZIP | Lat/Long`
- **Selection** stores selected address and triggers investigation initiation
- **Keyboard navigation:** Arrow keys to cycle results, Enter to select, Escape to close

#### 5.1.2 Recent Searches
- **Sidebar or top-right menu** displays last 10 addresses searched by this analyst
- **Click to reopen** an investigation from history
- **Clear history** option (local storage only; no backend persistence in MVP)
- **Timestamp** shown for each (e.g., "Today at 2:34 PM")

#### 5.1.3 Saved Investigations (MVP Feature)
- **Save button** on investigation dashboard saves current graph + metadata
- **Saved folder** lists all saved investigations with:
  - Address
  - Date saved
  - Number of entities in graph
  - Last accessed date
- **Load** reopens saved investigation, reloading graph from backend cache
- **Delete** removes saved investigation from local storage
- Storage: Browser IndexedDB + backend cache (optional sync)

#### 5.1.4 Manual Batch Address Input (Future Feature)
- CSV upload with addresses
- Queue for processing
- Batch status dashboard

---

### 5.2 Investigation Initiation

#### 5.2.1 Submission Flow
1. Analyst enters address → system validates format
2. If valid → **Investigation Dashboard** loads with:
   - Address header with map pin
   - Data source status panel (fetching...)
   - 3 skeleton-loaded metric cards
3. Backend immediately initiates connector pipeline:
   - Fires 30+ queries in parallel to OSINT sources
   - Returns entities + relationships as they complete
4. Dashboard updates in real-time as data arrives
5. Once 80% of sources complete → graph view available
6. Analyst can switch to graph view anytime; graph updates as new data arrives

#### 5.2.2 Validation & Error Handling
- **Invalid address:** Toast notification "Address not found. Please refine your search."
- **Query timeout (>2 min):** Partial results shown; data source marked as "timeout"
- **Rate limited:** Data source marked as "rate limited" with retry button
- **Network error:** Retry button; option to continue with cached results if available

---

### 5.3 Investigation Dashboard

#### 5.3.1 Overview Cards (3–5 Cards)
Each card is expandable; click to drill into category.

**Card 1: Property Overview**
- Property address (formatted)
- Parcel ID
- Year built
- Square footage
- Estimated value (if available)
- Owner name(s) + ownership type (individual, LLC, etc.)
- Last deed transaction date
- Source: Gwinnett County assessor, county deed records

**Card 2: Residents & Associates**
- Count of identified residents
- Count of associates (people linked via property/business)
- Click to expand: List of names with:
  - Relationship type (resident, owner, officer, relative)
  - Confidence score
  - Source
- Source: Census, voter registration, property records, business filings

**Card 3: Data Records Found**
- Count of court cases
- Count of business filings/registrations
- Count of permits
- Count of vehicle registrations
- Count of other records
- Source: Court databases, SEC, EPA, vehicle registration

**Card 4: Risk Indicators** (Optional; future feature)
- Flags for high-risk associations, legal issues, etc.

**Card 5: Timeline**
- Visual timeline of major events (property transfer, court case filed, business registered, etc.)
- Vertical timeline; click event to jump to graph view with that entity highlighted

#### 5.3.2 Map View
- Embedded Mapbox/Google Maps showing:
  - Primary address pinned
  - Nearby addresses with associated entities (if within 0.5 mi)
  - Click map pin to drill into that address (future feature: address pivot)
- Map controls: Zoom, pan, satellite toggle
- Overlay option to show "clusters" of activity

#### 5.3.3 Quick Action Links
- **View Full Graph** button (primary CTA)
- **Export as Report** (PDF; future feature)
- **Filter Results** (modal to select data sources, entity types to include in graph)
- **Refresh Data** (re-run all connectors; useful if new data expected)

#### 5.3.4 Data Source Status Panel
- Table/list showing:
  - Source name (Census, FBI, County Assessor, etc.)
  - Status: Querying | Complete | Failed | Rate Limited | Timeout
  - % Progress (for in-progress)
  - Entities found (for completed)
  - Timestamp (when query started/completed)
  - Retry button (if failed)
- Sortable by status, name, or entities found
- Expand source to see raw query details (debug info)

#### 5.3.5 Navigation
- **Back to Search:** Return to address input
- **View Full Graph:** Transition to graph view (main feature)
- **Save Investigation:** Save dashboard state + graph to local storage

---

### 5.4 Relationship Graph View (PRIMARY FEATURE)

#### 5.4.1 Graph Rendering & Layout
- **Library:** Neovis.js (recommended) or Vis.js with Neo4j backend
- **Physics simulation:** Force-directed layout (repelling forces between nodes, attractive forces along edges)
- **Real-time updates:** As new data arrives from backend, nodes/edges animate in
- **Initial view:** Entire graph visible on first render (auto-fit to viewport)
- **Viewport controls:** Zoom (mouse wheel, pinch), pan (drag), reset view (button)
- **Performance optimization:** Lazy loading for graphs >200 entities; show top N by degree, user can load more
- **Clustering:** Nodes auto-cluster by entity type (optional toggle)

#### 5.4.2 Entity Type Definitions & Styling

**Entity types are visually distinct across all views. Define shape, color, icon, and edge styling:**

| Entity Type | Shape | Color | Icon | Example | Node Size |
|---|---|---|---|---|---|
| Person | Circle | Blue (#3B82F6) | Head silhouette | John Smith | Medium |
| Address | House | Orange (#F59E0B) | House icon | 123 Main St, Atlanta GA | Large |
| Business | Pentagon/Box | Green (#10B981) | Building icon | ABC LLC | Medium |
| Vehicle | Diamond | Purple (#8B5CF6) | Car icon | 2020 Honda Civic (VIN) | Small |
| Court Case | Gavel | Red (#EF4444) | Gavel icon | Case #2024-1234 | Medium |
| Property Record | Document | Gray (#6B7280) | Document icon | Deed recorded 2020 | Small |
| Legal Entity (LLC, Corp) | Rounded Square | Teal (#14B8A6) | Briefcase | XYZ Holdings Inc | Medium |
| Phone Number | Phone | Pink (#EC4899) | Phone icon | (404) 555-1234 | Small |
| Email Address | Envelope | Indigo (#6366F1) | Envelope icon | john@example.com | Small |

**Node styling rules:**
- **Size:** Proportional to node "importance" (degree centrality); min 20px, max 60px
- **Border:** 2px solid; if selected, 4px with highlight color
- **Label:** Entity name inside node (if room); truncate with ellipsis
- **Hover state:** Border glow, tooltip with full name + entity type
- **Selected state:** Border highlight, detail panel opens on right

#### 5.4.3 Edge (Relationship) Styling

**Edge appearance indicates relationship type:**

| Relationship Type | Edge Style | Color | Label | Example |
|---|---|---|---|---|
| Resides At | Solid | Blue | "resides" | Person → Address |
| Owns | Solid Bold | Green | "owns" | Person → Address or Business |
| Officer Of | Dashed | Green | "officer" | Person → Business/LLC |
| Relative Of | Dotted | Purple | "relative" | Person → Person |
| Filed Against | Solid | Red | "filed" | Person → Court Case |
| Associate Of | Dotted | Gray | "associate" | Person → Person |
| Located At | Solid | Orange | "at" | Business → Address |
| Vehicle Registered To | Solid | Purple | "registered" | Vehicle → Person |
| Deed Transfer | Solid | Orange | "transferred" | Address → Address (chain of ownership) |

**Edge styling rules:**
- **Weight/thickness:** Proportional to confidence score (0.5–3px)
- **Arrows:** Directional arrow on tail (if relationship is directed); bidirectional arrows if mutual
- **Label:** Relationship type; appears on hover or can be toggled always-visible
- **Color saturation:** Lower saturation = lower confidence
- **Hover state:** Highlight edge and both connected nodes; show tooltip with relationship date/source

#### 5.4.4 Graph Interaction Patterns

**Left-click on node:**
- Open detail panel on right (see 5.5)
- Highlight node + adjacent edges
- Optionally zoom to node

**Right-click on node (context menu):**
- Expand (show 1-hop connections, up to max 3 hops)
- Collapse (hide all but direct connections to this node)
- Hide (remove node from view; add to "hidden" list with undo)
- Pin (lock position; prevent physics sim from moving)
- Search related (search graph for similar entities)
- Open in new tab (drill into entity via API)

**Left-click on edge:**
- Highlight relationship
- Open simplified detail panel showing:
  - Source entity name
  - Relationship type
  - Target entity name
  - Relationship date
  - Data source
  - Confidence score

**Left-click on empty space:**
- Deselect current node
- Close detail panel
- Clear edge highlights

**Drag node:**
- If unlocked: Move node (physics sim temporarily disabled for dragged node)
- If locked (pinned): No-op
- On release: Physics resumes

**Double-click to fit node in view**

**Keyboard shortcuts:**
- `Escape`: Deselect
- `Ctrl+A` / `Cmd+A`: Select all visible nodes
- `Delete`: Remove selected node(s) from view (with undo)
- `+` / `-`: Zoom in/out
- `Space`: Toggle physics simulation (freeze/unfreeze layout)
- `R`: Reset view (fit entire graph)
- `H`: Show/hide labels

#### 5.4.5 Graph Controls (Top Toolbar)

**Layout controls:**
- **Physics toggle** (play/pause icon): Freeze/unfreeze force simulation
- **Reset view** (home icon): Auto-fit graph to viewport
- **Zoom in/out** buttons (or slider)
- **Cluster toggle**: Group nodes by entity type in concentric circles (vs. force-directed)

**Filtering & search:**
- **Entity type filter** (dropdown/checkboxes): Show/hide specific entity types
- **Search box**: Highlight nodes matching text (name, ID); show results count
- **Confidence threshold slider**: Hide edges below X% confidence (0–100%)
- **Timeline slider** (see 5.4.6)

**Data controls:**
- **Refresh graph** (reload latest data from backend)
- **Export graph** (see 5.4.7)

**Right sidebar:**
- **Legend** (collapsible): Entity type colors/icons, edge styles
- **Statistics panel** (collapsible):
  - Total entities: X
  - Total relationships: Y
  - Entity type breakdown (pie chart or list)
  - Relationship type breakdown

#### 5.4.6 Timeline Slider
- **Horizontal slider** at bottom of graph view
- **Range:** Minimum date (earliest entity in graph) to today
- **Interaction:**
  - Drag slider to filter entities by "discovery date" or "relationship establishment date"
  - All entities discovered before slider date shown in full color
  - Entities discovered after slider date shown faded/grayed
  - Edges to future entities hidden
- **Display:** Label showing date range (e.g., "Showing relationships through June 2024")
- **Use case:** Analyst can see how graph "grew" over time; useful for understanding when connections formed

#### 5.4.7 Graph Export
- **Export button** opens dialog with options:
  - **Image (PNG/SVG):** Screenshot of current viewport
  - **Full image:** Entire graph rendered as large PNG (may be very large)
  - **JSON/CSV:** Raw graph data (nodes + edges) for external analysis
  - **PDF report:** Graph + entity stats + data provenance (future feature)
- **Resolution settings:** For image export, allow 1x–4x scale
- **File names:** Auto-generate from address + timestamp

---

### 5.5 Entity Detail Panel

#### 5.5.1 Triggering & Layout
- **Triggered by:** Left-click on any node in graph
- **Position:** Slides in from right side of screen
- **Size:** ~350–400px wide, full height
- **Scrollable:** If content exceeds viewport height
- **Close:** X button (top-right), or click empty graph space, or Escape key

#### 5.5.2 Panel Content

**Header:**
- Entity type icon + name (large, bold)
- Entity type label (e.g., "Person", "Address")
- ID or alternate identifier (if applicable)

**Tabs (organized by data category):**

**Tab 1: Overview**
- Key facts about entity:
  - If Person: Age, DOB, current/last known addresses, email, phone(s)
  - If Address: Property details (assessed value, square footage, year built), ownership, tax info
  - If Business: Business name, type (LLC/Corp/Sole Prop), registration date, status, address, officers
  - If Vehicle: Make, model, year, color, VIN, license plate, registration date
  - If Court Case: Case number, date filed, case type, parties, status, court
- Each field shows data + source attribution (see 5.5.3)

**Tab 2: Relationships**
- List of all connected entities (incoming + outgoing)
- Format: Entity name | Relationship type | Date | Confidence score | Source
- Sortable by name, date, confidence
- Click any relationship to highlight in graph and jump to that entity
- Show relationship details on click (popup or expand in place)

**Tab 3: Timeline**
- Vertical timeline of all events involving this entity:
  - Date
  - Event type (moved to address, filed court case, registered vehicle, etc.)
  - Description
  - Source
- Sortable chronologically (default) or by importance
- Click event to jump to related entity in graph

**Tab 4: Sources**
- Table of data sources that contributed to this entity's profile:
  - Source name
  - Date queried
  - Data provided (list of fields)
  - Confidence (how reliable source is)
  - Link to raw source (if public URL available)
- Allows analyst to assess data quality and verify facts independently

**Tab 5: Enrichment (Optional)**
- **Enrich button:** Trigger deeper search on this entity specifically
- Shows available enrichment options:
  - Deep people search (additional databases)
  - Business background check
  - Property history deep-dive
- Status display for in-progress enrichments

#### 5.5.3 Data Provenance & Source Attribution
- **Every field** in the detail panel includes an attribution:
  - Inline: Small (i) icon next to value; hover to see source name + query date
  - Or: Subtle source label (e.g., "per Census 2020")
- **Color coding (optional):** Source icon with color indicating data freshness/reliability:
  - Green: Recent (< 1 month)
  - Yellow: Moderate (1–6 months)
  - Gray: Older (> 6 months)

#### 5.5.4 Confidence Scoring
- **Per-entity confidence:** Overall rating (0–100%) summarizing data quality
  - 90–100%: High confidence (multiple independent sources agree)
  - 70–89%: Medium confidence (primary source verified, or single authoritative source)
  - 50–69%: Low confidence (single source, some corroboration)
- **Per-field confidence:** Individual fields scored; hover to see reasoning
- **Display:** Bar chart or percentage badge

#### 5.5.5 Actions
- **Enrich** button (if applicable): Trigger deeper search for this entity
- **Hide from graph** button: Remove node from graph view
- **Pin node** toggle: Lock position in physics sim
- **Copy to clipboard**: Copy entity details as formatted text (for sharing notes)
- **View raw data**: Collapse/expand raw JSON from all sources (debug view)

---

### 5.6 Data Source Status Panel

#### 5.6.1 Location & Triggers
- **Primary location:** Investigation dashboard (left sidebar or expandable modal)
- **Secondary location:** Graph view (collapsible sidebar or modal)
- **Always accessible** to analyst during investigation

#### 5.6.2 Display Format
- **Table view** (default):
  - Columns: Source Name | Status | Entities Found | Last Updated | Action
  - Rows: One per data source (30+ rows; scrollable)
  - Status icons: ✓ (complete), ⟳ (querying), ✗ (failed), ⏱ (timeout), ⚠ (rate limited)
- **Summary stats** (above table):
  - X sources complete
  - Y sources in progress
  - Z sources failed/timeout

#### 5.6.3 Status Values
- **Querying**: Source connector is actively fetching data; show progress % if available
- **Complete**: Source returned data; show count of entities found (e.g., "5 entities")
- **Failed**: Source returned error; show error message (e.g., "API unreachable")
- **Timeout**: Source exceeded query time limit; show timeout threshold (e.g., "Timeout after 30s")
- **Rate Limited**: Source returned 429 (too many requests); show estimated retry time
- **Not Queried**: Source not relevant to investigation (e.g., FBI entity search for a residential address)

#### 5.6.4 Actions Per Source
- **Retry button**: Available for Failed, Timeout, Rate Limited statuses
  - Click to re-queue source connector
  - Resets timer; shows "Querying..." again
- **Details button** (chevron/arrow): Expand row to show:
  - Full source name + description
  - Query parameters used
  - Raw error message (if failed)
  - Timestamp (when query started/completed)
  - Link to source documentation (external)

#### 5.6.5 Filtering & Sorting
- **Filter by status**: Show all | Complete | In Progress | Failed
- **Sort by**: Name | Status | Entities Found | Last Updated
- **Expandable categories**: Group sources by type (County Records, Federal, Business, Courts, etc.)

#### 5.6.6 Notifications
- **Toast notification** when source completes (optional; can be dismissed)
- **Sidebar badge** showing count of newly completed sources since last view

---

### 5.7 Saved Investigations & History

#### 5.7.1 Save Flow
- **Save button** on dashboard or graph view
- **Modal appears:**
  - Auto-generated name: Address + timestamp (e.g., "123 Main St, Atlanta - Mar 16, 2026")
  - Editable name field
  - Optional notes field (e.g., "Suspect in Case #2024-1234")
  - Checkbox: "Save graph snapshot" (vs. re-query when opened)
- **On save:** Store in browser IndexedDB + optional backend sync
- **Confirmation:** Toast "Investigation saved"

#### 5.7.2 Saved Investigations List
- **Access:** Menu button (top-left or top-right)
- **Modal shows:**
  - List of saved investigations
  - Address | Date Saved | Notes | Entities Count
  - Click to open (loads from cache)
  - Options menu per investigation: Rename, Delete, Export, Duplicate
- **Search/filter**: Filter by address, date range, notes

#### 5.7.3 Open Saved Investigation
- **Click** saved investigation in list
- **Load behavior:**
  - If graph snapshot saved: Display cached graph immediately (0.1s load time)
  - If graph snapshot NOT saved: Re-query all sources (slower, but fresh data)
- **Option to:** Refresh data (re-query) even if snapshot exists

---

### 5.8 Data Connector System (Backend Specification)

#### 5.8.1 Connector Architecture
- **Modular design:** Each data source is a separate "connector"
- **Async execution:** Connectors run in parallel; graph updates as data arrives
- **Timeout protection:** Max 30s per connector query
- **Fallback behavior:** If connector fails, continue with other sources

#### 5.8.2 Connector List (30+ Sources; MVP Includes High-Priority)

**Priority 1 (MVP - Live at Launch):**
1. Gwinnett County Property Records (assessor, GIS)
2. Georgia Secretary of State (business filings, corporate records)
3. Gwinnett County Court Records (civil, criminal case dockets)
4. USPS Address Database
5. Google Maps / Mapbox (geocoding)
6. OpenAI Embeddings API (optional: semantic search)

**Priority 2 (MVP - First 30 Days):**
7. FBI Most Wanted Database
8. EPA Facility Registry
9. SEC EDGAR (public company filings)
10. Georgia Department of Revenue (sales tax registrations)
11. Vehicle Registration (state DMV databases)
12. Voter Registration (public records)

**Priority 3 (MVP - Build-Out):**
13. Property Tax Records (multi-state)
14. ACS Census Data (American Community Survey)
15. Permits & Violations (Gwinnett + state)
16. Licensing Boards (professional licenses)
17. UCC Filings (Georgia Secretary of State)
18. Bankruptcy Records (US Courts)
19. PACER (Federal Court records)
20–30. Additional sources (LLCs, property deed registries, sex offender registries, etc.)

#### 5.8.3 Connector Return Format (Standard)
Each connector returns JSON:
```json
{
  "source_name": "Gwinnett County Assessor",
  "status": "success|failure|timeout|rate_limited",
  "entities": [
    {
      "id": "unique_id",
      "type": "Address|Person|Business|Vehicle|CourtCase|PropertyRecord|LegalEntity",
      "data": {
        "name_or_address": "...",
        "details": {...}
      },
      "confidence": 0.95,
      "discovered_date": "2026-03-16"
    }
  ],
  "relationships": [
    {
      "source_entity_id": "...",
      "target_entity_id": "...",
      "relationship_type": "owns|resides|officer|filed_against|...",
      "date": "2024-06-15",
      "confidence": 0.90,
      "source": "Gwinnett County Assessor"
    }
  ],
  "timestamp": "2026-03-16T14:23:45Z",
  "execution_time_ms": 1234,
  "error_message": null
}
```

#### 5.8.4 Connector Deduplication & Merging
- **Backend responsibility** (not UI):
  - Match entities across sources (same person, same address, etc.)
  - Merge duplicate entities
  - Aggregate confidence scores
  - Resolve conflicting data (e.g., different phone numbers for same person)
- **Strategy:** Fuzzy matching on names/addresses; exact match on IDs (SSN, VIN, case number, etc.)

---

### 5.9 Audit Logging & Compliance

#### 5.9.1 Logged Events
Every investigation action is logged server-side:
- **Investigation initiated:** Address searched, timestamp, user IP (optional)
- **Data sources queried:** Which connectors ran, start/end time, success/failure
- **Graph accessed:** Timestamp, number of entities, user agent
- **Entity examined:** Which entity detail panels opened, duration viewed
- **Data exported:** What data exported, format, timestamp
- **Investigation saved:** Saved name, timestamp

#### 5.9.2 Audit Log Access
- **Not exposed in MVP UI** (backend logging only)
- **Future feature:** Admin dashboard to view audit logs per user/address
- **Compliance:** Logs stored for 90 days minimum

#### 5.9.3 Data Retention
- **Cached graph data:** Retained for 30 days
- **Saved investigations:** Retained as long as analyst keeps them
- **Audit logs:** Retained for 90 days

---

## 6. NON-FUNCTIONAL REQUIREMENTS

### 6.1 Performance

| Metric | Target | Rationale |
|---|---|---|
| Address autocomplete response | <300ms | Must feel responsive for typing |
| Investigation initiation (first entities visible) | <2s | Analyst needs feedback immediately |
| Graph rendering (up to 500 entities) | <3s | Smooth UX, no waiting |
| Single entity detail panel load | <500ms | Quick information lookup |
| Data source query completion (80% of sources) | <30s | Analyst shouldn't wait >30s for results |
| Graph zoom/pan interaction | <16ms (60 fps) | Smooth interaction |
| Graph export | <5s | Reasonable export time |
| Search/filter in graph | <100ms | Responsive typing |

### 6.2 Scalability
- **Graph size:** Support up to 500 entities without performance degradation
- **Concurrent users:** Handle 100+ concurrent investigations (backend load balancing)
- **Data source load:** 30+ parallel queries per investigation
- **Browser memory:** Keep graph rendering under 500MB for graphs <500 entities
- **Lazy loading:** For graphs >200 entities, load top N by degree; user can request more

### 6.3 Reliability
- **Uptime:** 99% (MVP; 99.9% post-MVP)
- **Connector failure handling:** If one source fails, continue with others (don't block investigation)
- **Timeout protection:** All queries max 30s; exceed = mark as timeout + allow retry
- **Data freshness:** Sources queried fresh on each investigation (no caching between investigations, except within 24h grace period)
- **Graph auto-save:** Save graph state to browser every 30s (in case of crash)

### 6.4 Security
- **HTTPS only:** All traffic encrypted
- **CORS:** Restrict API calls to whitelisted origins
- **Rate limiting:** 10 investigations/minute per IP (prevent abuse)
- **Input validation:** Validate addresses, filter malicious input
- **No authentication required for MVP:** (Future feature: user accounts, API keys)
- **Data exposure:** All data is public (sourced from public records); no PII redaction required

### 6.5 Accessibility
- **WCAG 2.1 AA compliance** for dashboard & detail panels
- **Graph view:** Accessible keyboard navigation (arrow keys, Enter, Escape)
- **Color contrast:** All UI elements meet 4.5:1 minimum contrast ratio
- **Alt text:** All icons have alt text
- **Screen reader support:** Announce data source status changes, new entities discovered
- **Responsive design:** Mobile-first CSS (graph view desktop-only in MVP)

### 6.6 Browser Support
- **Modern browsers only** (MVP):
  - Chrome/Chromium: Latest 2 versions
  - Firefox: Latest 2 versions
  - Safari: Latest 2 versions
  - Edge: Latest version
- **Mobile/tablet:** Not supported in MVP (future feature)
- **IE11:** Not supported

### 6.7 Data Quality
- **Confidence scoring:** Every entity & relationship includes 0–100% confidence
- **Source attribution:** Every fact traced to source + query date
- **Duplicate handling:** Backend deduplicates entities across sources
- **Conflict resolution:** When sources disagree, show all versions + confidence scores

### 6.8 API Design (Backend)
- **REST API** (FastAPI)
- **Endpoints required:**
  - `POST /api/v1/investigation/initiate` (submit address)
  - `GET /api/v1/investigation/{investigation_id}` (get graph + metadata)
  - `GET /api/v1/investigation/{investigation_id}/status` (check data source status)
  - `GET /api/v1/entity/{entity_id}` (get entity details)
  - `POST /api/v1/investigation/{investigation_id}/save` (save investigation)
  - `GET /api/v1/investigation/saved` (list saved investigations)
  - `GET /api/v1/sources` (list available data sources)
- **Response format:** JSON
- **Error responses:** Standard HTTP status codes (400, 404, 429, 500) + error messages

---

## 7. USER STORIES

### 7.1 Scenario: Detective Maria Chen Investigates a Suspect Address

**User Story 1.1: Address Search**
```
As a detective, I want to enter an address and see autocomplete suggestions,
so that I can quickly find the correct property without typos.

Acceptance Criteria:
Given the address search field is focused,
When I type "123 main st at",
Then within 300ms I see up to 10 address suggestions including:
  - 123 Main Street, Atlanta, GA 30303 (matching)
  - 123 Main Avenue, Athens, GA 30601 (partial match)
  - Addresses should show lat/long in small gray text
And when I click a suggestion,
Then the system initiates an investigation and loads the dashboard.

Edge Cases:
  - Empty input: Show recent searches or empty state message
  - Ambiguous address (multiple matches): All suggestions should be shown
  - Address not found: Toast "No results. Try a different address."
  - Invalid format: Still attempt search (system is forgiving)
```

**User Story 1.2: Investigation Initiation & Data Loading**
```
As a detective, I want to see data loading immediately after submitting an address,
so that I know the system is working and can switch to the graph view anytime.

Acceptance Criteria:
Given I've selected an address from autocomplete,
When the investigation initiates,
Then within 2 seconds I see:
  - Investigation dashboard with address header
  - Data source status panel showing "Querying..." for all sources
  - Skeleton loaders for metric cards
And data sources complete in real-time (cards update as sources finish),
And once 80% of sources complete, "View Full Graph" button is enabled,
And I can click it anytime to switch to graph view (even if some sources still loading).

Edge Cases:
  - Address invalid: Show error within 2s
  - Network timeout: Show "Connection error. Retry?" button
  - All sources fail: Show error state with retry button
```

**User Story 1.3: View Relationship Graph**
```
As a detective, I want to see all entities (people, properties, businesses)
connected to the address as an interactive graph,
so that I can visually understand relationships and spot suspicious connections.

Acceptance Criteria:
Given the investigation is loaded and I click "View Full Graph",
When the graph view renders,
Then I see:
  - A force-directed graph showing the target address (large orange house icon) at center
  - Connected entities (persons as blue circles, businesses as green boxes, etc.) arranged around it
  - Edges labeled with relationship types (owns, resides, officer, etc.)
  - Graph is zoomable (mouse wheel), pannable (drag), and auto-fits to viewport
And the graph is interactive:
  - Click any node → detail panel opens on right showing entity info
  - Right-click → context menu with Expand/Collapse/Hide/Pin options
  - Hover node → tooltip with entity name + type
  - Drag node → move it (physics frozen for that node)
And graph updates in real-time if more data arrives from connectors.

Edge Cases:
  - No relationships found: Show isolated address node + empty graph message
  - Very large graph (>500 entities): Show "Loading more..." and allow analyst to trigger full load
  - Graph layout too crowded: Provide clustering toggle to group by entity type
```

**User Story 1.4: Explore Entity Details**
```
As a detective, I want to click any node and see detailed information about that entity,
so that I can verify facts and understand why it's connected to the address.

Acceptance Criteria:
Given I'm viewing the relationship graph,
When I click on any node,
Then a detail panel slides in from the right showing:
  - Entity name + icon
  - Overview tab with key facts (for person: age, DOB, addresses; for property: assessed value, year built, owner)
  - Each fact includes a source attribution (hover to see data source + query date)
  - Relationships tab showing all connected entities + relationship dates
  - Timeline tab showing events (moved to address, registered vehicle, filed court case)
  - Sources tab listing all data sources that contributed to entity profile
And when I click a related entity in the Relationships tab,
Then the graph highlights that entity + edges, and I can click to open its detail panel.

Edge Cases:
  - Entity has no data: Show "No additional information found" message
  - Data sources conflict (e.g., different phone numbers): Show both with confidence scores
  - Very long fact list: Panel scrolls; tabs prevent overflow
```

**User Story 1.5: Monitor Data Source Status**
```
As a detective, I want to see which data sources have completed, are in progress,
or failed,
so that I know whether to wait for more data or investigate with partial results.

Acceptance Criteria:
Given the investigation is running,
When I view the Data Source Status panel,
Then I see:
  - A table with all 30+ sources listed
  - Status column showing: ✓ (complete), ⟳ (querying), ✗ (failed), ⚠ (rate limited)
  - Entities Found column showing count (once complete)
  - For failed sources, a "Retry" button
And I can sort by status, name, or entities found,
And when I click "Retry" on a failed source,
Then it re-queues and shows "Querying..." again.

Edge Cases:
  - All sources fail: Show error state; offer "Refresh" button to re-initiate investigation
  - Source rate limited: Show estimated retry time (e.g., "Available in 30 seconds")
  - Source timeout: Show duration it was querying (e.g., "Timeout after 30s")
```

**User Story 1.6: Save Investigation**
```
As a detective, I want to save an investigation by address,
so that I can return to it later without re-querying all sources.

Acceptance Criteria:
Given I'm viewing an investigation,
When I click the "Save Investigation" button,
Then a modal appears with:
  - Auto-generated name (e.g., "123 Main St, Atlanta - Mar 16, 2026")
  - Editable name field
  - Optional notes field (e.g., "Suspect in Case #2024-1234")
And when I click "Save",
Then:
  - Investigation is stored in browser IndexedDB (+ backend cache if available)
  - Toast notification "Investigation saved"
  - A "Saved Investigations" menu appears with the saved investigation
And I can later access it via the menu and open it in <1 second (from cache).

Edge Cases:
  - User saves same address twice: Offer to overwrite previous or create duplicate
  - Browser storage full: Show "Storage full. Delete old investigations?" prompt
  - Backend sync fails: Still save locally; show "Saved locally (backup failed)"
```

---

### 7.2 Scenario: Investigative Journalist James Rodriguez Digs Deep

**User Story 2.1: Search Related Entities**
```
As a journalist, I want to search for entities within the graph that match certain criteria,
so that I can find hidden patterns (e.g., all businesses owned by the same person).

Acceptance Criteria:
Given I'm viewing a graph,
When I click the Search box and type "John",
Then the system highlights all nodes with "John" in the name,
And shows a results count (e.g., "3 matches"),
And I can cycle through matches with arrow keys or click individual results.

Edge Cases:
  - No matches: Show "No results" message
  - Too many matches (>50): Show first 10 + "Show more" button
```

**User Story 2.2: Filter by Entity Type**
```
As a journalist, I want to show/hide specific entity types in the graph,
so that I can focus on relevant connections (e.g., hide vehicles to reduce clutter).

Acceptance Criteria:
Given I'm viewing a graph,
When I click the "Entity Type Filter" dropdown,
Then I see checkboxes for all entity types (Person, Address, Business, Vehicle, Court Case, etc.),
And unchecking a type instantly hides all nodes of that type from the graph,
And edges to hidden nodes are also hidden.

Edge Cases:
  - User hides all entity types: Show "No entities visible" message + "Show all" button
```

**User Story 2.3: Export Graph for Publication**
```
As a journalist, I want to export the graph as an image or data format,
so that I can include it in my article or share it with colleagues.

Acceptance Criteria:
Given I'm viewing a graph,
When I click the "Export" button,
Then a modal appears with options:
  - Image (PNG) - current viewport
  - Image (PNG) - full graph (high-res)
  - JSON - graph data (nodes + edges)
  - CSV - node and edge data in table format
And when I select an option,
Then the file downloads automatically (named by address + timestamp).

Edge Cases:
  - Full graph is very large (>10,000 nodes): Show warning "Large export (50MB+)"
  - Export fails: Show "Export failed. Try again?" button
```

**User Story 2.4: Temporal Analysis with Timeline Slider**
```
As a journalist, I want to see how relationships formed over time,
so that I can understand the sequence of events and spot unusual patterns.

Acceptance Criteria:
Given I'm viewing a graph,
When I use the Timeline slider at the bottom,
Then:
  - Slider shows a date range from earliest entity to today
  - Dragging the slider filters entities by discovery date
  - Entities discovered after the slider date appear faded/grayed
  - Edges to future entities are hidden
  - Label shows "Showing relationships through [date]"
And I can see how the graph "grows" as I move the slider forward in time.

Edge Cases:
  - All entities discovered on same date: Show slider but no visual change
  - No date information for some entities: Show them regardless of slider position
```

---

### 7.3 Scenario: Corporate Investigator Priya Patel Performs Due Diligence

**User Story 3.1: Verify Data Source Attribution**
```
As a corporate investigator, I want to verify the source of every fact claimed,
so that I can assess reliability and share findings with our legal team.

Acceptance Criteria:
Given I'm viewing an entity detail panel,
When I look at any data field (e.g., "Owner: John Smith"),
Then I see a small source attribution (icon or label),
And when I hover over it,
Then I see:
  - Data source name (e.g., "Gwinnett County Assessor")
  - Query date (e.g., "Mar 15, 2026")
  - Confidence score (e.g., "95%")
  - Optional: Link to raw source data
And in the "Sources" tab,
Then I see a full table of all sources that contributed to this entity's profile.

Edge Cases:
  - Data comes from multiple sources: Show both; note any conflicts
  - Source data is very old: Mark with yellow warning
  - Source is less reliable: Show with lower confidence score
```

**User Story 3.2: Assess Relationship Confidence**
```
As a corporate investigator, I want to understand how confident the system is
that a relationship exists,
so that I don't base legal decisions on weak connections.

Acceptance Criteria:
Given I'm viewing a graph,
When I click on any edge (relationship),
Then a detail popup shows:
  - Source entity name
  - Relationship type
  - Target entity name
  - Confidence score (0–100%)
  - Explanation (e.g., "Cross-referenced 2 sources: County Deed + SEC EDGAR")
And edges are color-saturation coded (higher confidence = more saturated).

Edge Cases:
  - Relationship has very low confidence (<50%): Still show it, but warn analyst
  - Only one source supports relationship: Show confidence 60–70% depending on source reliability
```

**User Story 3.3: Drill into Property Ownership Chain**
```
As a corporate investigator, I want to see the full chain of property ownership over time,
so that I can understand if the property passed through suspicious entities.

Acceptance Criteria:
Given I'm viewing a graph with a property address as the primary node,
When I click the "Expand" option on the property node,
Then the graph shows:
  - The property address (center)
  - Previous owners (as nodes connected by "transferred_to" edges)
  - Dates on each transfer (e.g., "transferred 2020-06-15")
  - Connected to each owner node are their other properties + businesses
And I can click any owner to see details (name, entity type, other properties).

Edge Cases:
  - Property has very long ownership history (>20 owners): Show last 10 + "Load more" option
  - Some transfers pre-date available records: Show gap in chain
```

---

### 7.4 Scenario: Civic Researcher Alex Kim Analyzes Real Estate Patterns

**User Story 4.1: Generate Network Statistics**
```
As a civic researcher, I want to see statistical summaries of the network,
so that I can write about ownership patterns and concentration.

Acceptance Criteria:
Given I'm viewing a graph,
When I open the Statistics panel (sidebar),
Then I see:
  - Total entities: X
  - Total relationships: Y
  - Breakdown by entity type (pie chart or bar chart):
    - Persons: X
    - Addresses: Y
    - Businesses: Z
    - etc.
  - Breakdown by relationship type:
    - Owns: X%
    - Resides: Y%
    - Officer: Z%
    - etc.
  - Network density (how interconnected)
  - Clustering coefficient (how grouped entities are)
And I can export these statistics as a CSV for further analysis.

Edge Cases:
  - Graph is very small (<5 entities): Show basic stats only
  - Statistics take time to compute: Show "Computing..." spinner
```

**User Story 4.2: Compare Multiple Addresses**
```
As a civic researcher, I want to investigate multiple addresses and compare their networks,
so that I can identify patterns of concentrated ownership.

Acceptance Criteria (Future Feature):
Given I'm in the Address Search view,
When I enter multiple addresses (via CSV upload or manual entry),
Then the system initiates parallel investigations for all addresses,
And I can view them in a comparison dashboard showing:
  - Side-by-side graphs
  - Overlapping entities highlighted
  - Statistics for each address
And I can merge graphs to see the consolidated network.

Note: This is a future feature; not in MVP.
```

---

### 7.5 General Cross-Cutting User Stories

**User Story 5.1: Keyboard Navigation**
```
As any analyst, I want to navigate and interact with the graph using keyboard shortcuts,
so that I can work efficiently without reaching for the mouse.

Acceptance Criteria:
Given the graph has focus,
When I press these keys:
  - Arrow keys: Cycle through selected nodes
  - Enter: Open detail panel for selected node
  - Escape: Deselect node, close panels
  - Delete: Remove selected node from view (with undo)
  - Ctrl+A / Cmd+A: Select all nodes
  - +/-: Zoom in/out
  - Space: Toggle physics simulation (freeze/unfreeze)
  - R: Reset view (fit entire graph)
  - H: Show/hide labels
Then the graph responds accordingly.

Edge Cases:
  - No node is selected: Arrow keys should select first node
  - Ctrl+A with no nodes: No-op
  - Delete with no node selected: No-op
```

**User Story 5.2: Graph Performance on Large Datasets**
```
As any analyst, I want the graph to remain responsive even with 500 entities,
so that I can analyze large investigations without lag.

Acceptance Criteria:
Given a graph has 500 entities,
When I interact with it (pan, zoom, click nodes, drag nodes),
Then:
  - Pan/zoom latency < 16ms (60 fps)
  - Click-to-panel-open latency < 500ms
  - Drag-to-move latency < 50ms
  - Search/filter latency < 100ms
And I do not experience browser crashes or memory exhaustion.

Edge Cases:
  - Graph approaches 1000 entities: Show warning "Very large graph. Consider filtering by entity type."
  - Browser memory <100MB free: Show warning "Browser low on memory. Close other tabs?"
```

**User Story 5.3: Graceful Handling of Incomplete Data**
```
As any analyst, I want the system to show me the best data available,
even if some sources fail,
so that I can still conduct analysis without waiting for a perfect result.

Acceptance Criteria:
Given an investigation is running,
When some data sources fail or timeout,
Then:
  - The graph shows entities + relationships from successful sources
  - Failed sources are marked as "Failed" in the status panel
  - A toast notification offers "Retry failed sources" button
  - No critical workflow is blocked
And the analyst can choose to retry later or continue with available data.

Edge Cases:
  - All sources fail: Show error state with "Refresh" button
  - Very few sources succeed (<5): Show warning "Limited data. Results may be incomplete."
```

---

## 8. ACCEPTANCE CRITERIA SUMMARY

Below is a consolidated test matrix that QA/Test team can use to validate each feature:

| Feature | Test Case | Given | When | Then | Status |
|---|---|---|---|---|---|
| **Address Input** | Autocomplete works | User types in search field | Types "123 main" | 5–10 suggestions appear <300ms | MVP |
| | | User hits Escape | Autocomplete is open | Suggestions close; field clears | MVP |
| | Invalid address | User submits invalid format | Submits "xyz" | Error toast appears | MVP |
| | Recent searches | User returns to app | Clicks Recent menu | Last 10 addresses shown | MVP |
| **Investigation Init** | Data loading | User submits address | Dashboard loads | Skeleton loaders + status panel visible in <2s | MVP |
| | | User clicks "View Graph" | <80% sources complete | Graph available; button works | MVP |
| | Error handling | Sources fail | >5 retries fail | Error state shown; retry button available | MVP |
| **Graph Rendering** | Node display | Graph loads | Graph has entities | All entity types colored correctly + labeled | MVP |
| | | User zooms | Mousewheel or pinch | Zoom in/out smooth (<16ms latency) | MVP |
| | | User pans | Drag on graph | Pan smooth, no lag | MVP |
| | Edge display | Graph loads | Relationships exist | Edges labeled with type + date | MVP |
| | | User hovers edge | Edge under cursor | Tooltip shows relationship details | MVP |
| | Scale limits | Graph has >200 entities | Graph renders | Lazy loading or clustering active | MVP |
| **Entity Detail** | Panel opens | User clicks node | Node is selected | Detail panel slides in <500ms | MVP |
| | | User clicks empty space | Panel is open | Panel closes; node deselects | MVP |
| | Content tabs | Panel is open | User views each tab | Overview, Relationships, Timeline, Sources visible | MVP |
| | Source attribution | Panel shows fact | Analyst hovers source icon | Tooltip shows source name + date | MVP |
| | Confidence score | Analyst views relationship | Relationship displayed | Confidence 0–100% shown | MVP |
| **Graph Interaction** | Context menu | User right-clicks node | Menu appears | Expand, Collapse, Hide, Pin, Search options shown | MVP |
| | | User clicks "Hide" | Node hidden | Node removed from view; undo option available | MVP |
| | | User clicks "Pin" | Node pinned | Node locked in place; physics doesn't move it | MVP |
| | Filtering | User filters by entity type | Unchecks "Vehicle" | All vehicles disappear; edges adjusted | MVP |
| | | User searches "John" | 3 entities match | All Johns highlighted; count shown | MVP |
| | Timeline slider | User drags timeline | Date changed | Entities after date fade; edges hidden | MVP |
| **Data Sources** | Status display | Investigation running | User views status panel | All sources listed with status (✓/⟳/✗/⚠) | MVP |
| | | Source completes | Status shows "Complete" | Entity count updated | MVP |
| | | Source fails | Retry button visible | User clicks; source re-queues | MVP |
| | Rate limiting | Source rate limited | Status shows "⚠ Rate Limited" | Estimated retry time shown | MVP |
| **Save Investigation** | Save flow | User clicks Save button | Modal appears | Pre-filled name; notes field visible | MVP |
| | | User saves | Investigation saved | Toast "Saved"; appears in menu | MVP |
| | Load from history | User opens Saved menu | List shown | Click to open in <1s | MVP |
| | | Graph snapshot enabled | User opens saved | Graph loads from cache immediately | MVP |
| **Export** | Image export | User clicks Export | Modal shown | PNG/SVG options visible | MVP |
| | | User selects PNG | File downloads | Named by address + timestamp | MVP |
| | Data export | User selects JSON | File downloads | Valid JSON with nodes + edges | MVP |
| **Accessibility** | Keyboard nav | Graph focused | User presses Arrow keys | Nodes cycle; selected node highlighted | MVP |
| | | User presses Enter | Detail panel opens | For selected node | MVP |
| | Screen reader | Detail panel open | Screen reader active | Fields announced with labels | MVP |
| | Color contrast | Any UI element | Visual inspection | 4.5:1 contrast ratio verified | MVP |

---

## 9. INFORMATION ARCHITECTURE & NAVIGATION

### 9.1 Navigation Hierarchy

```
Home / Address Search (Entry Point)
├── Address Input
│   ├── Autocomplete
│   ├── Recent Searches
│   └── Saved Investigations
├── Help / Documentation (Future)
└── Settings (Future)

Investigation Dashboard (After Address Selected)
├── Overview Cards
│   ├── Property Details
│   ├── Residents & Associates
│   ├── Records Found
│   ├── Risk Indicators (Future)
│   └── Timeline
├── Map View
├── Data Source Status Panel
├── Quick Actions
│   ├── View Full Graph (Primary CTA)
│   ├── Export Report (Future)
│   ├── Filter Results
│   └── Refresh Data
└── Back to Search

Relationship Graph View (Primary Feature)
├── Graph Canvas (Center)
│   ├── Nodes (Entities)
│   │   ├── Click → Entity Detail Panel
│   │   ├── Right-click → Context Menu
│   │   └── Drag → Move (Physics Frozen)
│   └── Edges (Relationships)
│       ├── Click → Relationship Detail
│       └── Hover → Tooltip
├── Top Toolbar
│   ├── Layout Controls (Physics Toggle, Reset View, Zoom)
│   ├── Filtering (Entity Type, Search, Confidence Threshold)
│   ├── Timeline Slider
│   └── Export / Refresh
├── Right Sidebar
│   ├── Legend (Entity Types, Edge Styles)
│   └── Statistics Panel
├── Right Side Pane (When Node Selected)
│   └── Entity Detail Panel
│       ├── Overview Tab
│       ├── Relationships Tab
│       ├── Timeline Tab
│       ├── Sources Tab
│       └── Enrichment Tab (Optional)
└── Left Sidebar (Optional; Collapsible)
    └── Data Source Status Panel

Entity Detail Panel (Right Pane)
├── Header (Icon, Name, Type)
├── Overview Tab
│   ├── Key Facts (with source attribution)
│   ├── Confidence Score
│   └── "Enrich" Button
├── Relationships Tab
│   ├── Connected Entities List
│   └── Click Entity → Jump to Graph Node
├── Timeline Tab
│   ├── Chronological Events
│   └── Click Event → Jump to Related Entity
├── Sources Tab
│   ├── Data Sources Table
│   ├── Fields Provided per Source
│   └── Link to Raw Data
└── Actions
    ├── Hide from Graph
    ├── Pin Node
    ├── Copy to Clipboard
    └── View Raw JSON (Debug)

Context Menu (Right-click on Node)
├── Expand (Load 1-hop connections)
├── Collapse (Hide all but direct)
├── Hide (Remove from view)
├── Pin (Lock position)
├── Search Related
└── Open in New Tab
```

### 9.2 Screen Navigation Flows

**Flow 1: New Investigation**
```
Address Search
  ↓ (User enters address, hits Enter or clicks suggestion)
Investigation Dashboard (skeleton loaders visible)
  ↓ (Data sources report back in real-time)
Dashboard updates with metrics + timeline
  ↓ (User clicks "View Full Graph")
Relationship Graph View
```

**Flow 2: Explore Entity Details**
```
Relationship Graph View
  ↓ (User clicks node)
Entity Detail Panel opens (right sidebar)
  ↓ (User clicks related entity in Relationships tab)
Graph highlights related entity
  ↓ (User clicks highlighted entity)
Detail Panel updates to show new entity
```

**Flow 3: Save & Reopen**
```
Investigation Dashboard or Graph View
  ↓ (User clicks "Save Investigation")
Save Modal appears
  ↓ (User confirms)
Investigation saved to IndexedDB
  ↓ (User clicks Saved Investigations menu)
List of saved investigations shown
  ↓ (User clicks saved investigation)
Cached graph loads instantly
```

**Flow 4: Filter & Export**
```
Relationship Graph View
  ↓ (User unchecks entity types in filter)
Graph updates (entities hidden)
  ↓ (User clicks "Export")
Export modal appears
  ↓ (User selects PNG / JSON)
File downloads
```

---

## 10. ENTITY TYPE DEFINITIONS & VISUAL SPECIFICATIONS

### 10.1 Entity Type Palette (Comprehensive)

| Entity Type | Shape | Color | Hex | Icon | Example Data Fields | Node Size | Use Case |
|---|---|---|---|---|---|---|---|
| **Person** | Circle | Blue | #3B82F6 | Head silhouette | Name, DOB, Age, Email, Phone(s), Addresses, Relationships | Medium (30px) | Individuals, residents, officers, associates |
| **Address** | House | Orange | #F59E0B | House icon | Street, City, State, ZIP, Lat/Long, Parcel ID, Owner(s), Assessed Value, Year Built | Large (50px) | Primary node; residential or commercial properties |
| **Business** | Pentagon | Green | #10B981 | Building/company icon | Business Name, Business Type (LLC/Corp/Sole), Registration Date, Status, Address, Officers, Revenue (if public) | Medium (35px) | Registered businesses, companies, partnerships |
| **Vehicle** | Diamond | Purple | #8B5CF6 | Car icon | Make, Model, Year, Color, VIN, License Plate, Owner, Registration Date | Small (25px) | Registered vehicles linked to persons |
| **Court Case** | Gavel | Red | #EF4444 | Gavel icon | Case Number, Case Type (civil/criminal), Date Filed, Court, Parties, Status, Judge | Medium (35px) | Legal proceedings involving entities |
| **Property Record** | Document | Gray | #6B7280 | Document/file icon | Record Type (deed, mortgage, lien), Date, Parties, Description, Amount, Recording Number | Small (25px) | Deeds, mortgages, liens, tax records |
| **Legal Entity** | Rounded Square | Teal | #14B8A6 | Briefcase icon | Entity Name, Type (LLC/Corp/Partnership), Registration Date, Status, Agents, Dissolution Date (if applicable) | Medium (35px) | Corporate entities, LLCs, partnerships from Secretary of State |
| **Phone Number** | Phone | Pink | #EC4899 | Phone icon | Phone Number, Country Code, Type (mobile/landline) | Small (20px) | Contact information nodes |
| **Email Address** | Envelope | Indigo | #6366F1 | Envelope icon | Email Address, Domain | Small (20px) | Contact information nodes |
| **Organization** | Institution | Cyan | #06B6D4 | Institution icon | Organization Name, Type, Address, Leadership | Medium (35px) | Non-profits, government agencies, institutions |

### 10.2 Relationship Type Specifications

| Relationship | Direction | Edge Style | Color | Label | Confidence Guide | Example |
|---|---|---|---|---|---|---|
| **Resides At** | Person → Address | Solid | Blue | "resides" | 90–100% (if from Census/voter reg) | John Smith resides at 123 Main St |
| **Owns** | Person/Business → Address | Solid Bold | Green | "owns" | 95–100% (from deed records) | ABC LLC owns 456 Oak Ave |
| **Officer Of** | Person → Business | Dashed | Green | "officer" | 85–95% (from Secretary of State) | Mary Johnson is officer of ABC LLC |
| **Relative Of** | Person ↔ Person | Dotted | Purple | "relative" | 50–80% (from Census/genealogy) | John Smith related to Jane Smith |
| **Filed Against** | Person/Business → Court Case | Solid | Red | "filed" | 95–100% (from court records) | John Smith filed case #2024-1234 |
| **Associate Of** | Person ↔ Person | Dotted | Gray | "associate" | 60–80% (from business co-ownership) | John Smith associated with Mary Johnson |
| **Located At** | Business → Address | Solid | Orange | "at" | 90–100% (from business registration) | ABC LLC located at 789 Pine Rd |
| **Registered To** | Vehicle → Person | Solid | Purple | "registered" | 95–100% (from DMV) | 2020 Honda (VIN xyz) registered to John Smith |
| **Transferred To** | Address → Address | Solid | Orange | "transferred" | 95–100% (from deed chain) | 123 Main St transferred from [prev owner] to [new owner] on 2020-06-15 |
| **Controls** | Person/Business → Business | Dashed | Teal | "controls" | 70–85% (from filings, UCC) | John Smith controls ABC LLC |
| **Permitted For** | Address → Permit | Solid | Yellow | "permitted" | 95–100% (from permit records) | 123 Main St permitted for renovation in 2023 |
| **Defendant In** | Person → Court Case | Solid | Red | "defendant" | 95–100% (from court docket) | John Smith defendant in case #2024-1234 |
| **Plaintiff In** | Person → Court Case | Solid | Red | "plaintiff" | 95–100% (from court docket) | Mary Johnson plaintiff in case #2024-1234 |

### 10.3 Visual Styling Rules

**Node Styling:**
- **Size:** Proportional to centrality (degree in graph); clamped 20–60px
- **Border:** 2px solid (entity type color)
- **Label:** Entity name or identifier; white text, bold, center-aligned
- **Label truncation:** If name >20 chars, show "Name..." with full name in tooltip
- **Hover:** Border glow (2px expanded to 4px, +10% brightness)
- **Selected:** Border 4px with highlight color (#FFD700 gold)
- **Faded (timeline):** Opacity 40%, desaturated color
- **Icon:** 16–20px icon inside node, top-left or center (TBD by designer)

**Edge Styling:**
- **Stroke width:** 0.5–3px, proportional to confidence score
- **Stroke linecap:** round (smoother appearance)
- **Color saturation:** Higher confidence = more saturated; lower = more gray
- **Arrows:** Arrowhead on target node side (if directed); bidirectional for symmetric relationships
- **Label position:** Midpoint of edge; background white box, font-size 11px, text color matches edge
- **Hover:** Highlight edge + both nodes; tooltip shows relationship date + source
- **Faded (timeline):** Hidden if target entity is after timeline slider date

---

## 11. INTERACTION PATTERNS & MICROINTERACTIONS

### 11.1 Address Autocomplete

**User types:**
```
Input: "123 m"
       ↓
Request sent to API (debounced 200ms)
       ↓
Results arrive <300ms
       ↓
Dropdown shows 10 suggestions with smooth fade-in animation (200ms)
Position: Suggestions appear below input field, max-height 300px, scrollable
Highlight: Current selection has light background (e.g., #F0F9FF)
       ↓
User presses Down arrow
       ↓
Next suggestion highlighted (smooth color transition)
       ↓
User presses Enter or clicks suggestion
       ↓
Selection fills input field; dropdown closes
Investigation initiates
```

**Keyboard behavior:**
- Arrow Up/Down: Cycle through suggestions
- Enter: Select highlighted suggestion
- Escape: Close dropdown, clear selection
- Backspace: Delete last char, refetch if needed
- Tab: Select highlighted (move focus away)

---

### 11.2 Data Source Status Panel

**Initial state:** All sources show "Querying..." with spinner
```
Source Name | ⟳ Querying | — | —
         ↓ (0.5–30s later)
Source Name | ✓ Complete | 5 entities | 2:34 PM
```

**Failed source state:**
```
Source Name | ✗ Failed | — | Retry button
         ↓ (user clicks Retry)
Source Name | ⟳ Querying | — | —
         ↓ (success after retry)
Source Name | ✓ Complete | 2 entities | 2:40 PM
```

**Toast notification (when source completes):**
- Toast slides in from bottom-right
- Shows: "✓ Gwinnett County Assessor found 5 entities"
- Auto-dismisses after 4s OR user clicks X
- Color: Green (#10B981) background, white text
- Sound: Optional subtle notification sound (muted by default)

---

### 11.3 Graph Node Selection

**User clicks node:**
```
Node under cursor (no selection yet)
       ↓ (user clicks)
Node border animates: 2px → 4px (50ms)
Node color saturation: +10% (50ms)
Detail panel slides in from right (200ms ease-out)
       ↓ (detail panel now open)
Selected node border: 4px gold (#FFD700)
       ↓ (user clicks another node)
Old node border animates: 4px → 2px (50ms)
New node border animates: 2px → 4px (50ms)
Detail panel content updates (fade-out old, fade-in new; 100ms)
```

**Right-click context menu:**
```
User right-clicks node
       ↓
Menu appears at cursor position (fade-in 100ms)
Menu options: Expand | Collapse | Hide | Pin | Search Related
       ↓ (user clicks "Hide")
Node animates: opacity 1 → 0 (300ms)
Node removed from graph
Undo toast appears (bottom-left): "Node hidden. Undo?"
       ↓ (after 5s or user clicks elsewhere)
Undo toast fades out
```

---

### 11.4 Timeline Slider

**User drags slider:**
```
Slider at Jan 2020
       ↓ (user drags to Jan 2024)
All entities with discovery_date > Jan 2024:
  - Opacity: 1 → 0.4 (200ms)
  - Color: desaturated (−50% saturation)
  - Edges to future entities: hidden (200ms fade-out)
Label updates: "Showing relationships through Jan 2024"
       ↓ (user continues dragging to today)
Entities re-saturate, opacity returns to 1 (200ms)
Label: "Showing relationships through today"
```

---

### 11.5 Graph Zoom & Pan

**Mouse wheel zoom:**
```
Zoom speed: proportional to wheel delta
Min zoom: 0.5x (entire graph visible)
Max zoom: 5x (close-up on nodes)
Center: Mouse cursor position
Animation: Smooth ease-out (100ms)
```

**Pan (drag on empty graph space):**
```
User drags from (100, 200) to (200, 250)
       ↓
Graph translates by (100, 50) pixels (instant; no animation)
```

**Reset view button:**
```
User clicks "Reset View" (home icon)
       ↓
Graph animates to fit entire graph in viewport (500ms ease-out)
Zoom adjusted to show all nodes with 10% padding
```

---

### 11.6 Entity Detail Panel

**Opening animation:**
```
User clicks node
       ↓
Panel slides in from right: margin-right 0 → -400px (200ms ease-out)
Panel background fades in: opacity 0 → 1 (100ms)
Content fades in (staggered): headers first, then tabs (100ms offset)
```

**Tab switching:**
```
User clicks "Relationships" tab
       ↓
Old content fades out (100ms)
New content fades in (100ms)
Scroll position resets to top
```

**Closing animation:**
```
User clicks X button or clicks empty graph space
       ↓
Panel slides out: margin-right 0 → -400px (200ms ease-in)
Background fades out: opacity 1 → 0 (100ms)
Graph node deselection (border 4px → 2px, 50ms)
```

---

## 12. EDGE CASES & ERROR STATES

### 12.1 Address Validation

| Edge Case | Behavior | UX |
|---|---|---|
| Empty input | Do not send request | Empty state message: "Start typing an address" |
| Invalid format (e.g., "xyz") | Send request; API returns 0 results | "No results found. Try a different address." |
| Ambiguous address (multiple exact matches) | Return all matches | "10 results found. Showing closest matches." |
| Very long input (>200 chars) | Truncate to 200; warn user | Truncate silently (no warning necessary) |
| Special characters (e.g., @#$) | Filter; proceed with valid chars | "Removed special characters: @#$" |
| International address | Accept but note not supported | "This address is outside the USA. Results may be limited." |

### 12.2 Investigation Errors

| Error | Trigger | Recovery |
|---|---|---|
| Invalid address | User submits invalid address | "Address not found. Please refine your search." Toast; return to address input |
| Network timeout | Investigation runs >60s without response | "Connection timeout. Retry?" button; optionally show partial results |
| All sources fail | All 30 connectors return errors | "No data found. Check address or retry." Offer "Refresh" button |
| Backend unavailable | FastAPI server down | "Service unavailable. Try again in a few moments." Auto-retry every 5s |
| Rate limited (IP) | IP hits global rate limit | "Too many requests. Please wait X minutes." Auto-retry timer shown |

### 12.3 Graph Rendering Errors

| Error | Trigger | Recovery |
|---|---|---|
| Graph data corrupted | Malformed JSON from backend | Fallback to previous graph state; show toast "Graph data invalid. Using cached version." |
| No entities found | Investigation complete but 0 entities | Show isolated query node with message "No entities found for this address." |
| Very large graph (>500 entities) | Lazy loading activated | Show "Graph too large. Showing top 200 by degree. Load more?" Link to show 100 more at a time |
| Physics simulation crashes | Browser memory spike | Freeze physics simulation; show "Graph may be unstable. Reload?" button |
| Rendering lag (FPS drop) | Too many entities or weak GPU | Show "Performance mode: Hiding edges temporarily" warning; allow toggle |

### 12.4 Detail Panel Errors

| Error | Trigger | Recovery |
|---|---|---|
| Entity data empty | Entity returned no fields | "No additional information available for this entity. Try enriching." Show Enrich button |
| Confidence score unavailable | Data source didn't return confidence | Show "—" or "Unknown confidence" |
| Source link broken | External source URL invalid | Show "Source link unavailable" (don't expose broken link) |
| Very long data list (>100 fields) | Rare entities with extensive records | Show first 20 fields + "Show X more" link; paginate |

### 12.5 Data Source Status Errors

| Status | Message | Action |
|---|---|---|
| Failed | "API unreachable" | Show error message; Retry button |
| Timeout | "Timed out after 30s" | Show duration; Retry button |
| Rate Limited | "Rate limited. Available in 2:34" | Show countdown timer; auto-retry |
| Invalid API Key | "Authentication failed" | Show "Configuration error. Contact admin." (backend issue) |
| No Data | "Source returned 0 results" | Mark complete (not an error); show "0 entities" |

### 12.6 Save/Export Errors

| Error | Trigger | Recovery |
|---|---|---|
| Storage full (IndexedDB) | Browser local storage maxed out | "Storage full. Delete old investigations?" Offer list of old investigations to remove |
| Export file too large | Graph >10MB as JSON | "Export may be very large (50MB). Continue?" Warning dialog |
| Export timeout | Export takes >30s | "Export timed out. Try PNG instead?" |
| Backend cache unavailable | Saved investigation not in backend cache | Show "Using cached version" or "Re-querying sources..." |

### 12.7 Empty States

| Page | Condition | Message & Action |
|---|---|---|
| Address Search | First visit (no history) | "Enter an address to begin." Placeholder text in input; example address shown as hint |
| Recent Searches | No history | "No recent searches. Start a new investigation." |
| Saved Investigations | No saved investigations | "No saved investigations yet. Save one from the dashboard." |
| Graph View | No relationships found | "No relationships found for [address]. Try a different address or enrich." |
| Entity Detail | No data for tab | "No data available for this section." (e.g., Timeline tab with no dates) |
| Data Source Status | Awaiting sources | "Querying sources..." All sources show ⟳ Querying with 0% progress initially |

---

## 13. FUTURE FEATURES (POST-MVP)

These features are **not in scope for MVP** but should be designed with extensibility in mind.

### 13.1 Collaboration & Sharing
- **Save investigation and share link** with team members
- **Shared workspace** where multiple analysts work on same graph in real-time
- **Comments on entities/relationships** (threaded discussion)
- **Permissions model** (view-only, edit, admin)

### 13.2 Advanced Analytics
- **Centrality analysis**: Identify most connected entities (betweenness, closeness, degree)
- **Community detection**: Identify clusters of highly interconnected entities
- **Pattern matching**: Find similar subgraphs (e.g., "find other properties with same ownership pattern")
- **Risk scoring**: Automated flagging of high-risk associations
- **Timeline analysis**: Identify temporal patterns (e.g., all business registrations on same date)

### 13.3 Historical State Versioning
- **Rewind graph to date X**: See what relationships existed on that date
- **Timeline of graph changes**: When entities/relationships were added/removed
- **Change highlighting**: Show what's new since last investigation

### 13.4 Bulk Address Processing
- **CSV upload** with multiple addresses
- **Batch processing dashboard** showing progress
- **Consolidated report** comparing multiple addresses
- **Export all graphs** as PDF bundle

### 13.5 Advanced Enrichment
- **Custom data source connectors**: Analysts can add private data sources (e.g., proprietary databases)
- **Manual entity creation**: Add custom entities not found in public sources
- **Relationship annotation**: Add context/notes to relationships
- **AI-powered insights**: LLM-generated summaries of findings

### 13.6 User Accounts & Auth
- **User login** with email + password (or OAuth)
- **Investigation history** persisted across sessions/devices
- **Audit logging** (who searched what, when)
- **API keys** for programmatic access

### 13.7 Mobile & Tablet Optimization
- **Responsive design** for tablets (iPad)
- **Touch optimizations** for graph interaction
- **Mobile app** (iOS/Android) with offline support

### 13.8 Export & Reporting
- **PDF report generation** (graph + entity summary + data provenance)
- **PowerPoint deck** with key findings
- **Legal-ready documentation** with chain-of-custody information

---

## 14. DEPENDENCIES & INTEGRATIONS

### 14.1 External APIs & Services

| Service | Purpose | MVP | Fallback |
|---|---|---|---|
| Google Maps / Mapbox API | Address geocoding + map display | Required | OpenStreetMap (free tier) |
| Neo4j Graph Database | Store and query relationship graphs | Required | N/A |
| Neovis.js / Vis.js | Graph visualization library | Required | N/A |
| Gwinnett County GIS API | Property records (local MVP focus) | Required | Web scraping (slower) |
| Georgia Secretary of State API | Business filings | Required | Web scraping |
| Google Census API | Demographics data | Required | ACS Census (free) |
| FBI API | Most wanted, crime records | Required | Public scraping (if available) |
| OpenAI Embeddings API | Semantic search (optional) | Optional | Skip semantic features |
| RapidAPI (connector hub) | Various data connectors | Optional | Direct API integration |

### 14.2 Frontend Dependencies
- **React 18+** (UI framework)
- **TailwindCSS 3+** (styling)
- **shadcn/ui** (component library)
- **Neovis.js** or **Vis.js** (graph rendering)
- **Mapbox GL** or **Google Maps SDK** (map display)
- **React Router** (navigation)
- **Zustand** or **Jotai** (state management)
- **Tanstack React Query** (server state)
- **Framer Motion** (animations; optional)

### 14.3 Backend Dependencies
- **FastAPI** (Python web framework)
- **Neo4j Python Driver** (graph database)
- **Aiohttp** (async HTTP for parallel queries)
- **Pydantic** (data validation)
- **SQLAlchemy** (optional; audit logging to SQL)
- **Redis** (optional; caching, rate limiting)
- **Celery** (optional; background tasks)

---

## 15. OPEN QUESTIONS & FUTURE CLARIFICATIONS

1. **PII Handling**: Should analyst be able to redact names before exporting? (Compliance consideration)
2. **Search History Persistence**: Should search history sync to backend, or local-only?
3. **Batch Investigation Limits**: Once bulk processing added, what's the max batch size? (100 addresses? 10,000?)
4. **Rate Limiting per User**: Should we rate-limit by IP or require user auth for per-user limits?
5. **Connector Prioritization**: If multiple sources return conflicting data, which source wins? (Heuristic: "US Government > County > Private")
6. **Graph Export Formats**: Should we support other formats (GraphML, GexF) for tools like Gephi?
7. **Accessibility Testing**: What's the accessibility standard (WCAG 2.1 AA or AAA)?
8. **Performance Profiling**: At what entity count do we need to activate lazy loading? (MVP assumes 200; future maybe 500)
9. **Data Freshness SLA**: How often are sources re-queried? (Daily? Weekly? On-demand with cache busting?)
10. **Compliance & Legal**: Are we liable if analysis is used for discriminatory purposes? (Product needs terms of service)

---

## 16. READY-TO-BUILD SPEC SUMMARY

This specification is **complete and ready for handoff** to Architecture and Development teams.

### What's Included
✓ Complete problem statement & user personas
✓ 20+ user stories with detailed acceptance criteria
✓ Screen-by-screen UX flows
✓ Entity type definitions with visual specifications
✓ Relationship type definitions with styling rules
✓ Interaction patterns & microinteractions
✓ Information architecture & navigation hierarchy
✓ Edge cases & error handling
✓ API requirements (FastAPI, Neo4j, connectors)
✓ Performance & accessibility targets
✓ MVP vs. future feature delineation

### Next Steps
1. **Architecture Agent**: Review tech stack choices (React + Neovis.js + FastAPI + Neo4j); propose detailed system design
2. **Frontend Developer**: Implement screens in order (Address Search → Dashboard → Graph View → Detail Panel)
3. **Backend Developer**: Implement FastAPI endpoints, Neo4j schema, connector system
4. **Test & QA Agent**: Use acceptance criteria to build test plan
5. **Issue Manager**: Convert user stories into GitHub issues with links to this spec

### Handoff Artifacts
- This spec document (PRODUCT_SPEC.md)
- Entity type design file (colors, icons, shapes) - **to be created by Design/Frontend**
- Wireframes (optional; may use this spec + designer's judgment)
- API specification (OpenAPI/Swagger) - **to be created by Architect**

---

**End of Product Specification**

*Prepared by: Product & UX Agent*
*Date: 2026-03-16*
*Status: Ready for Architecture & Development*
