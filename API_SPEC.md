# Eagle Eye: API Specification

**Version:** 1.0
**Date:** 2026-03-16
**Framework:** FastAPI
**Database:** Neo4j
**Status:** Ready for Backend Implementation

---

## 1. API OVERVIEW

### Base URL
```
Production: https://api.eagleeye.local/api/v1
Development: http://localhost:8000/api/v1
```

### Authentication
**MVP:** No authentication (public API)
**Future:** Bearer token (JWT) via Authorization header

### Response Format
All responses are JSON. Error responses include standard HTTP status codes.

### Rate Limiting
- **Global:** 100 requests/minute per IP
- **Investigation endpoint:** 10 new investigations/minute per IP
- **Response headers:**
  ```
  X-RateLimit-Limit: 100
  X-RateLimit-Remaining: 95
  X-RateLimit-Reset: 1710670800
  ```

---

## 2. REQUEST/RESPONSE MODELS

### Standard Response Envelope
```json
{
  "status": "success" | "error",
  "data": {},
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable error message",
    "details": {}
  },
  "timestamp": "2026-03-16T14:23:45.123Z"
}
```

### Error Response Example
```json
{
  "status": "error",
  "data": null,
  "error": {
    "code": "INVALID_ADDRESS",
    "message": "Address format invalid or not found",
    "details": {
      "input": "xyz",
      "suggestions": ["Check spelling", "Provide full address"]
    }
  },
  "timestamp": "2026-03-16T14:23:45.123Z"
}
```

### Pagination
For list endpoints, paginate with `limit` and `offset` query params:
```
GET /api/v1/saved-investigations?limit=10&offset=20
```

Response includes:
```json
{
  "data": [...],
  "pagination": {
    "limit": 10,
    "offset": 20,
    "total": 147,
    "has_next": true,
    "has_prev": true
  }
}
```

---

## 3. ENDPOINTS

### 3.1 Address Autocomplete

**Endpoint:** `GET /api/v1/address/autocomplete`

**Query Parameters:**
| Param | Type | Required | Description |
|---|---|---|---|
| query | string | Yes | Partial address (e.g., "123 main") |
| country | string | No | Country code (default: "US") |
| state | string | No | Filter by state code (e.g., "GA") |
| limit | integer | No | Max results (default: 10, max: 50) |

**Example Request:**
```
GET /api/v1/address/autocomplete?query=123+main&state=GA&limit=10
```

**Success Response (200):**
```json
{
  "status": "success",
  "data": {
    "results": [
      {
        "address": "123 Main Street, Atlanta, GA 30303",
        "latitude": 33.7490,
        "longitude": -84.3880,
        "place_id": "ChIJ...",
        "types": ["premise", "postal_code"],
        "score": 0.95
      },
      {
        "address": "123 Main Avenue, Athens, GA 30601",
        "latitude": 33.9519,
        "longitude": -83.3747,
        "place_id": "ChIJ...",
        "types": ["premise"],
        "score": 0.87
      }
    ],
    "query": "123 main",
    "count": 2
  },
  "timestamp": "2026-03-16T14:23:45.123Z"
}
```

**Error Response (400):**
```json
{
  "status": "error",
  "error": {
    "code": "INVALID_QUERY",
    "message": "Query must be at least 3 characters"
  }
}
```

---

### 3.2 Initiate Investigation

**Endpoint:** `POST /api/v1/investigation`

**Request Body:**
```json
{
  "address": "123 Main Street, Atlanta, GA 30303",
  "latitude": 33.7490,
  "longitude": -84.3880,
  "place_id": "ChIJ...",
  "search_radius_miles": 0.5,
  "max_hops": 3,
  "entity_types_filter": ["Person", "Business", "Address"],
  "source_filters": ["gwinnett_assessor", "ga_secretary_state", "census"]
}
```

**Request Fields:**
| Field | Type | Required | Description |
|---|---|---|---|
| address | string | Yes | Full address (e.g., "123 Main St, Atlanta, GA 30303") |
| latitude | float | Yes | Latitude of address (geocoded) |
| longitude | float | Yes | Longitude of address (geocoded) |
| place_id | string | No | Place ID from geocoding service (for caching) |
| search_radius_miles | float | No | Radius for nearby entity search (default: 0.5 miles) |
| max_hops | integer | No | Max relationship hops (default: 3, max: 5) |
| entity_types_filter | array | No | Entity types to include (default: all) |
| source_filters | array | No | Data sources to query (default: all) |

**Success Response (201):**
```json
{
  "status": "success",
  "data": {
    "investigation_id": "inv_abc123def456",
    "address": "123 Main Street, Atlanta, GA 30303",
    "latitude": 33.7490,
    "longitude": -84.3880,
    "created_at": "2026-03-16T14:23:45.123Z",
    "status": "querying",
    "sources_total": 30,
    "sources_querying": 30,
    "sources_complete": 0,
    "entities_found": 0,
    "relationships_found": 0
  },
  "timestamp": "2026-03-16T14:23:45.123Z"
}
```

**Error Response (400):**
```json
{
  "status": "error",
  "error": {
    "code": "INVALID_ADDRESS",
    "message": "Address not found",
    "details": {
      "input": "xyz"
    }
  }
}
```

**Note:** Investigation immediately begins querying all sources asynchronously. Response includes investigation_id for polling status.

---

### 3.3 Get Investigation Status

**Endpoint:** `GET /api/v1/investigation/{investigation_id}`

**Path Parameters:**
| Param | Type | Description |
|---|---|---|
| investigation_id | string | Investigation ID returned from initiate endpoint |

**Query Parameters:**
| Param | Type | Default | Description |
|---|---|---|---|
| include_graph | boolean | true | Include full graph data (nodes + edges) |
| include_sources | boolean | true | Include data source status |

**Example Request:**
```
GET /api/v1/investigation/inv_abc123def456?include_graph=true&include_sources=true
```

**Success Response (200):**
```json
{
  "status": "success",
  "data": {
    "investigation_id": "inv_abc123def456",
    "address": "123 Main Street, Atlanta, GA 30303",
    "latitude": 33.7490,
    "longitude": -84.3880,
    "created_at": "2026-03-16T14:23:45.123Z",
    "updated_at": "2026-03-16T14:24:12.456Z",
    "overall_status": "complete",
    "graph": {
      "nodes": [
        {
          "id": "addr_123",
          "type": "Address",
          "data": {
            "address": "123 Main Street, Atlanta, GA 30303",
            "parcel_id": "12345678",
            "owner": "ABC LLC",
            "assessed_value": 450000,
            "year_built": 2005,
            "square_footage": 2500
          },
          "confidence": 0.98,
          "discovered_date": "2026-03-16",
          "sources": ["gwinnett_assessor", "zillow"]
        },
        {
          "id": "person_001",
          "type": "Person",
          "data": {
            "name": "John Smith",
            "age": 35,
            "dob": "1991-03-15",
            "email": "john@example.com",
            "phone": "+1-404-555-1234",
            "addresses": ["123 Main Street, Atlanta, GA 30303"]
          },
          "confidence": 0.92,
          "discovered_date": "2026-03-16",
          "sources": ["census", "voter_registration"]
        },
        {
          "id": "biz_456",
          "type": "Business",
          "data": {
            "name": "ABC LLC",
            "type": "Limited Liability Company",
            "status": "Active",
            "registration_date": "2015-06-20",
            "address": "123 Main Street, Atlanta, GA 30303",
            "officers": ["John Smith", "Mary Johnson"]
          },
          "confidence": 0.95,
          "discovered_date": "2026-03-16",
          "sources": ["ga_secretary_state"]
        }
      ],
      "edges": [
        {
          "id": "edge_001",
          "source": "person_001",
          "target": "addr_123",
          "relationship_type": "resides",
          "relationship_date": "2024-01-15",
          "confidence": 0.96,
          "source_name": "census",
          "direction": "outgoing"
        },
        {
          "id": "edge_002",
          "source": "biz_456",
          "target": "addr_123",
          "relationship_type": "located_at",
          "relationship_date": "2015-06-20",
          "confidence": 0.99,
          "source_name": "ga_secretary_state",
          "direction": "outgoing"
        },
        {
          "id": "edge_003",
          "source": "person_001",
          "target": "biz_456",
          "relationship_type": "officer",
          "relationship_date": "2015-06-20",
          "confidence": 0.98,
          "source_name": "ga_secretary_state",
          "direction": "outgoing"
        }
      ]
    },
    "sources": [
      {
        "name": "Gwinnett County Assessor",
        "source_id": "gwinnett_assessor",
        "status": "complete",
        "entities_found": 3,
        "relationships_found": 2,
        "started_at": "2026-03-16T14:23:45.123Z",
        "completed_at": "2026-03-16T14:23:51.234Z",
        "execution_time_ms": 6111,
        "error": null
      },
      {
        "name": "Census Bureau",
        "source_id": "census",
        "status": "complete",
        "entities_found": 5,
        "relationships_found": 4,
        "started_at": "2026-03-16T14:23:45.123Z",
        "completed_at": "2026-03-16T14:24:02.567Z",
        "execution_time_ms": 17444,
        "error": null
      },
      {
        "name": "Georgia Secretary of State",
        "source_id": "ga_secretary_state",
        "status": "querying",
        "entities_found": 1,
        "relationships_found": 1,
        "started_at": "2026-03-16T14:23:45.123Z",
        "completed_at": null,
        "execution_time_ms": null,
        "error": null
      },
      {
        "name": "FBI Most Wanted",
        "source_id": "fbi",
        "status": "failed",
        "entities_found": 0,
        "relationships_found": 0,
        "started_at": "2026-03-16T14:23:45.123Z",
        "completed_at": "2026-03-16T14:23:47.890Z",
        "execution_time_ms": 2767,
        "error": "API unreachable (503 Service Unavailable)"
      }
    ],
    "statistics": {
      "total_entities": 18,
      "total_relationships": 24,
      "entity_type_breakdown": {
        "Person": 8,
        "Address": 5,
        "Business": 3,
        "Vehicle": 2,
        "CourtCase": 0
      },
      "relationship_type_breakdown": {
        "resides": 5,
        "owns": 3,
        "officer": 4,
        "associate": 12
      }
    }
  },
  "timestamp": "2026-03-16T14:24:12.456Z"
}
```

**Polling Recommendations:**
- Poll every 2–3 seconds while `overall_status == "querying"`
- Stop polling when `overall_status == "complete"` or `"failed"`
- Long-polling (wait for changes) is optional future enhancement

---

### 3.4 Get Entity Details

**Endpoint:** `GET /api/v1/entity/{entity_id}`

**Path Parameters:**
| Param | Type | Description |
|---|---|---|
| entity_id | string | Entity ID (e.g., "person_001", "addr_123") |

**Query Parameters:**
| Param | Type | Default | Description |
|---|---|---|---|
| investigation_id | string | Optional | Investigation context (for relationship filtering) |

**Example Request:**
```
GET /api/v1/entity/person_001?investigation_id=inv_abc123def456
```

**Success Response (200):**
```json
{
  "status": "success",
  "data": {
    "entity_id": "person_001",
    "type": "Person",
    "name": "John Smith",
    "data": {
      "name": "John Smith",
      "age": 35,
      "dob": "1991-03-15",
      "email": "john@example.com",
      "phone": "+1-404-555-1234",
      "addresses": [
        {
          "address": "123 Main Street, Atlanta, GA 30303",
          "type": "current",
          "move_date": "2024-01-15"
        },
        {
          "address": "456 Oak Avenue, Marietta, GA 30060",
          "type": "previous",
          "move_date": "2020-06-30"
        }
      ],
      "relationships": {
        "owns": ["biz_456"],
        "resides": ["addr_123"],
        "officer": ["biz_456"]
      }
    },
    "confidence": {
      "overall": 0.92,
      "per_field": {
        "name": 0.98,
        "dob": 0.85,
        "email": 0.90,
        "phone": 0.88
      }
    },
    "sources": [
      {
        "source_id": "census",
        "source_name": "Census Bureau",
        "query_date": "2026-03-16",
        "fields_provided": ["age", "addresses", "dob"],
        "confidence": 0.95,
        "link": "https://data.census.gov"
      },
      {
        "source_id": "voter_registration",
        "source_name": "Voter Registration",
        "query_date": "2026-03-15",
        "fields_provided": ["name", "address", "dob"],
        "confidence": 0.98,
        "link": null
      }
    ],
    "timeline": [
      {
        "date": "2024-01-15",
        "event": "Moved to 123 Main Street, Atlanta, GA 30303",
        "sources": ["census", "voter_registration"]
      },
      {
        "date": "2020-06-30",
        "event": "Moved to 456 Oak Avenue, Marietta, GA 30060",
        "sources": ["census"]
      }
    ]
  },
  "timestamp": "2026-03-16T14:24:12.456Z"
}
```

**Error Response (404):**
```json
{
  "status": "error",
  "error": {
    "code": "ENTITY_NOT_FOUND",
    "message": "Entity ID not found"
  }
}
```

---

### 3.5 Expand Entity (Load More Relationships)

**Endpoint:** `POST /api/v1/entity/{entity_id}/expand`

**Path Parameters:**
| Param | Type | Description |
|---|---|---|
| entity_id | string | Entity ID to expand |

**Request Body:**
```json
{
  "investigation_id": "inv_abc123def456",
  "hops": 1,
  "max_new_entities": 100,
  "entity_types_filter": ["Person", "Business"]
}
```

**Success Response (200):**
```json
{
  "status": "success",
  "data": {
    "entity_id": "person_001",
    "new_nodes": [
      {
        "id": "person_002",
        "type": "Person",
        "data": {...}
      }
    ],
    "new_edges": [
      {
        "source": "person_001",
        "target": "person_002",
        "relationship_type": "associate",
        "confidence": 0.75
      }
    ]
  }
}
```

---

### 3.6 Save Investigation

**Endpoint:** `POST /api/v1/investigation/{investigation_id}/save`

**Path Parameters:**
| Param | Type | Description |
|---|---|---|
| investigation_id | string | Investigation ID |

**Request Body:**
```json
{
  "name": "123 Main St, Atlanta - Suspect",
  "notes": "Potential drug operation based on business filings",
  "tags": ["suspect", "drugs", "2024-q1"],
  "include_graph_snapshot": true
}
```

**Success Response (201):**
```json
{
  "status": "success",
  "data": {
    "saved_investigation_id": "save_xyz789",
    "investigation_id": "inv_abc123def456",
    "name": "123 Main St, Atlanta - Suspect",
    "notes": "Potential drug operation based on business filings",
    "tags": ["suspect", "drugs", "2024-q1"],
    "saved_at": "2026-03-16T14:25:00.000Z",
    "cache_key": "cache_xyz789",
    "snapshot_included": true
  }
}
```

---

### 3.7 Get Saved Investigations

**Endpoint:** `GET /api/v1/saved-investigations`

**Query Parameters:**
| Param | Type | Default | Description |
|---|---|---|---|
| limit | integer | 10 | Results per page (max: 100) |
| offset | integer | 0 | Pagination offset |
| search | string | Optional | Search by name, notes, address |
| tag | string | Optional | Filter by tag |
| sort | string | "saved_at" | Sort by: name, saved_at, accessed_at |
| order | string | "desc" | asc or desc |

**Example Request:**
```
GET /api/v1/saved-investigations?limit=10&offset=0&sort=saved_at&order=desc
```

**Success Response (200):**
```json
{
  "status": "success",
  "data": [
    {
      "saved_investigation_id": "save_xyz789",
      "investigation_id": "inv_abc123def456",
      "address": "123 Main Street, Atlanta, GA 30303",
      "name": "123 Main St, Atlanta - Suspect",
      "notes": "Potential drug operation based on business filings",
      "tags": ["suspect", "drugs", "2024-q1"],
      "saved_at": "2026-03-16T14:25:00.000Z",
      "accessed_at": "2026-03-16T14:25:00.000Z",
      "entity_count": 18,
      "relationship_count": 24
    },
    {
      "saved_investigation_id": "save_abc123",
      "investigation_id": "inv_def456ghi789",
      "address": "456 Oak Avenue, Marietta, GA 30060",
      "name": "456 Oak Ave, Marietta - Due Diligence",
      "notes": "Corporate acquisition target",
      "tags": ["corporate", "due_diligence"],
      "saved_at": "2026-03-15T10:20:00.000Z",
      "accessed_at": "2026-03-15T14:00:00.000Z",
      "entity_count": 12,
      "relationship_count": 18
    }
  ],
  "pagination": {
    "limit": 10,
    "offset": 0,
    "total": 23,
    "has_next": true,
    "has_prev": false
  }
}
```

---

### 3.8 Load Saved Investigation

**Endpoint:** `GET /api/v1/saved-investigations/{saved_investigation_id}`

**Path Parameters:**
| Param | Type | Description |
|---|---|---|
| saved_investigation_id | string | Saved investigation ID (e.g., "save_xyz789") |

**Query Parameters:**
| Param | Type | Default | Description |
|---|---|---|---|
| refresh | boolean | false | Force re-query sources (vs. use cached snapshot) |

**Success Response (200):**
```json
{
  "status": "success",
  "data": {
    "saved_investigation_id": "save_xyz789",
    "investigation_id": "inv_abc123def456",
    "address": "123 Main Street, Atlanta, GA 30303",
    "name": "123 Main St, Atlanta - Suspect",
    "saved_at": "2026-03-16T14:25:00.000Z",
    "graph": {
      "nodes": [...],
      "edges": [...]
    },
    "sources": [...],
    "status": "loaded_from_cache"
  }
}
```

---

### 3.9 Delete Saved Investigation

**Endpoint:** `DELETE /api/v1/saved-investigations/{saved_investigation_id}`

**Success Response (204):**
No content (empty response body)

---

### 3.10 Get Available Data Sources

**Endpoint:** `GET /api/v1/sources`

**Query Parameters:**
| Param | Type | Default | Description |
|---|---|---|---|
| category | string | Optional | Filter by category: county, federal, business, courts, etc. |

**Success Response (200):**
```json
{
  "status": "success",
  "data": {
    "sources": [
      {
        "source_id": "gwinnett_assessor",
        "source_name": "Gwinnett County Assessor",
        "category": "county",
        "description": "Property records, tax assessments, parcel data",
        "entity_types": ["Address", "Person"],
        "relationship_types": ["owns", "resides"],
        "geographic_scope": "Gwinnett County, GA",
        "data_freshness": "daily",
        "coverage": 0.95,
        "status": "active"
      },
      {
        "source_id": "census",
        "source_name": "US Census Bureau",
        "category": "federal",
        "description": "Demographics, population, household data",
        "entity_types": ["Person", "Address"],
        "relationship_types": ["resides"],
        "geographic_scope": "USA",
        "data_freshness": "annually",
        "coverage": 0.85,
        "status": "active"
      },
      {
        "source_id": "fbi",
        "source_name": "FBI Most Wanted",
        "category": "federal",
        "description": "Federal crime records, most wanted",
        "entity_types": ["Person"],
        "relationship_types": ["filed_against"],
        "geographic_scope": "USA",
        "data_freshness": "real-time",
        "coverage": 0.02,
        "status": "active"
      }
    ],
    "total": 30,
    "active": 28,
    "disabled": 2
  }
}
```

---

### 3.11 Manually Retry Data Source

**Endpoint:** `POST /api/v1/investigation/{investigation_id}/source/{source_id}/retry`

**Path Parameters:**
| Param | Type | Description |
|---|---|---|
| investigation_id | string | Investigation ID |
| source_id | string | Data source ID (e.g., "gwinnett_assessor") |

**Success Response (200):**
```json
{
  "status": "success",
  "data": {
    "investigation_id": "inv_abc123def456",
    "source_id": "gwinnett_assessor",
    "retry_status": "querying",
    "retry_count": 1,
    "previous_error": "Timeout after 30s"
  }
}
```

---

### 3.12 Export Graph Data

**Endpoint:** `GET /api/v1/investigation/{investigation_id}/export`

**Query Parameters:**
| Param | Type | Default | Description |
|---|---|---|---|
| format | string | "json" | Export format: json, csv, geojson |

**Formats:**

**JSON Export:**
```
GET /api/v1/investigation/inv_abc123def456/export?format=json
```
Response: `application/json`
```json
{
  "investigation_id": "inv_abc123def456",
  "address": "123 Main Street, Atlanta, GA 30303",
  "nodes": [...],
  "edges": [...]
}
```

**CSV Export:**
```
GET /api/v1/investigation/inv_abc123def456/export?format=csv
```
Response: Two CSV files (nodes.csv, edges.csv) in a ZIP archive

CSV Format (nodes.csv):
```
node_id,node_type,name,confidence,discovered_date
person_001,Person,John Smith,0.92,2026-03-16
addr_123,Address,123 Main Street, Atlanta, GA 30303,0.98,2026-03-16
biz_456,Business,ABC LLC,0.95,2026-03-16
```

CSV Format (edges.csv):
```
edge_id,source_node,target_node,relationship_type,relationship_date,confidence,source_name
edge_001,person_001,addr_123,resides,2024-01-15,0.96,census
edge_002,biz_456,addr_123,located_at,2015-06-20,0.99,ga_secretary_state
```

---

## 4. DATA MODELS (Neo4j / GraphQL)

### Node Properties

**Person Node**
```
{
  id: string (UUID)
  type: "Person"
  name: string
  dob: date
  age: int
  email: string
  phone: string
  addresses: [string]
  confidence: float (0-1)
  discovered_date: date
  sources: [string]
}
```

**Address Node**
```
{
  id: string (UUID)
  type: "Address"
  address: string (full address)
  street: string
  city: string
  state: string
  zip: string
  latitude: float
  longitude: float
  parcel_id: string
  owner: string
  ownership_type: string (individual|llc|corp|other)
  assessed_value: int
  year_built: int
  square_footage: int
  confidence: float (0-1)
  discovered_date: date
  sources: [string]
}
```

**Business Node**
```
{
  id: string (UUID)
  type: "Business"
  name: string
  business_type: string (llc|corp|partnership|sole_prop)
  registration_date: date
  status: string (active|inactive|dissolved)
  address: string
  officers: [string]
  revenue: int (optional)
  employees: int (optional)
  confidence: float (0-1)
  discovered_date: date
  sources: [string]
}
```

**CourtCase Node**
```
{
  id: string (UUID)
  type: "CourtCase"
  case_number: string
  case_type: string (civil|criminal|family|bankruptcy)
  date_filed: date
  court_name: string
  court_level: string (state|federal)
  parties: [string]
  status: string (active|closed|dismissed)
  judge: string (optional)
  confidence: float (0-1)
  discovered_date: date
  sources: [string]
}
```

**Vehicle Node**
```
{
  id: string (UUID)
  type: "Vehicle"
  make: string
  model: string
  year: int
  color: string
  vin: string
  license_plate: string
  owner: string
  registration_date: date
  confidence: float (0-1)
  discovered_date: date
  sources: [string]
}
```

### Relationship Properties

```
{
  type: string (resides|owns|officer|relative|filed_against|associate|located_at|registered_to|transferred_to|controls|permitted_for)
  date: date (when relationship was established)
  confidence: float (0-1)
  source_name: string
  direction: string (outgoing|incoming|bidirectional)
}
```

---

## 5. ERROR CODES

| Code | Status | Description | Recovery |
|---|---|---|---|
| INVALID_ADDRESS | 400 | Address format invalid or not found | Retry with different address |
| INVALID_QUERY | 400 | Request body validation failed | Fix request and retry |
| INVALID_ENTITY_ID | 404 | Entity ID not found | Verify entity_id |
| INVESTIGATION_NOT_FOUND | 404 | Investigation ID not found | Verify investigation_id |
| SAVED_INVESTIGATION_NOT_FOUND | 404 | Saved investigation not found | Verify saved_investigation_id |
| RATE_LIMIT_EXCEEDED | 429 | Too many requests | Wait and retry |
| SERVICE_UNAVAILABLE | 503 | Backend service down | Retry after delay |
| DATABASE_ERROR | 500 | Internal database error | Retry; contact support if persistent |

---

## 6. WEBHOOKS (FUTURE FEATURE)

Future enhancement: Server-sent events (SSE) or WebSockets for real-time updates instead of polling.

```
GET /api/v1/investigation/{investigation_id}/stream
```

Server sends events as data arrives:
```
event: source_complete
data: {"source_id": "gwinnett_assessor", "entities": 5, "relationships": 3}

event: source_failed
data: {"source_id": "fbi", "error": "API unreachable"}

event: investigation_complete
data: {"investigation_id": "inv_abc123def456"}
```

---

## 7. IMPLEMENTATION NOTES

### Backend Stack
- **Framework:** FastAPI (Python 3.10+)
- **Database:** Neo4j 5.x
- **Async:** asyncio + aiohttp for parallel source queries
- **API Documentation:** Swagger UI (auto-generated from FastAPI)

### Key Design Decisions
1. **Async/Await:** All source queries run in parallel; don't block on any single source
2. **Timeout Protection:** Each source has 30s max query time; exceed = mark as timeout
3. **Graph Caching:** Investigation graphs cached in Redis/Neo4j for 24 hours
4. **Deduplication:** Backend responsible for matching entities across sources
5. **Pagination:** Large lists (100+) are paginated; frontend requests more as needed

### Testing Endpoints (Mock Data)
```
POST /api/v1/dev/mock-investigation
  Returns pre-populated investigation for testing

POST /api/v1/dev/reset
  Clears all cached investigations (dev only)
```

---

**End of API Specification**

*This specification is the contract between Frontend and Backend teams.*
*Implement exactly as specified; deviations require explicit approval.*
