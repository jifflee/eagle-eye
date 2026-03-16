# Eagle Eye

Open Source Intelligence (OSINT) platform for address-based profiling with relationship graph visualization.

Enter an address and Eagle Eye automatically discovers residents, businesses, court records, property data, environmental data, and more — then visualizes all connections in an interactive Palantir-style graph.

## Quick Start

### Prerequisites
- Python 3.11+
- Node.js 20+
- Docker & Docker Compose (for databases)

### Backend

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
cp ../.env.example .env
uvicorn app.main:app --reload
```

Backend runs at http://localhost:8000. API docs at http://localhost:8000/docs.

### Frontend

```bash
cd frontend
npm install
npm run dev
```

Frontend runs at http://localhost:5173.

### Docker (Full Stack)

```bash
docker compose up
```

Starts all services: backend, frontend, Neo4j, PostgreSQL, Redis.

## Architecture

- **Backend:** Python / FastAPI / Celery
- **Frontend:** React / TypeScript / Vis.js / TailwindCSS
- **Graph DB:** Neo4j Community
- **Metadata DB:** PostgreSQL
- **Cache:** Redis

See [ARCHITECTURE.md](./ARCHITECTURE.md) for full system design.

## Data Sources

30+ OSINT connectors organized by tier:

- **Tier 1 (Free, no auth):** Census, FBI Crime, EPA, SEC EDGAR, CourtListener, FEMA, NHTSA
- **Tier 2 (Free, scraping):** Gwinnett County parcels, GA Secretary of State, county courts, deeds
- **Tier 3 (Free with limits):** OpenCorporates, Google Places, Hunter.io, NumVerify

See [OSINT_DATA_SOURCES.md](./OSINT_DATA_SOURCES.md) for complete inventory.

## Documentation

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | System architecture and tech stack |
| [PRODUCT_SPEC.md](./PRODUCT_SPEC.md) | Product spec, user stories, UX flows |
| [DESIGN_SYSTEM.md](./DESIGN_SYSTEM.md) | Visual design tokens and components |
| [API_SPEC.md](./API_SPEC.md) | REST API specification |
| [ISSUES.md](./ISSUES.md) | Epic and issue breakdown |

## License

MIT — see [LICENSE](./LICENSE)
