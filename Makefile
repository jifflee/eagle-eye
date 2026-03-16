.PHONY: help dev up down test demo status install backend frontend lint clean

# Default
help: ## Show this help
	@echo ""
	@echo "  Eagle Eye — OSINT Intelligence Platform"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

# === Setup ===

install: ## Install all dependencies (backend + frontend)
	@echo "Installing backend..."
	cd backend && python3 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]" -q
	@echo "Installing frontend..."
	cd frontend && npm install --silent
	@test -f .env || cp .env.example .env
	@echo "Done. Run 'make dev' to start."

# === Development ===

dev: ## Start backend + frontend for local development
	@$(MAKE) -j2 backend frontend

backend: ## Start FastAPI backend (port 8000)
	cd backend && . .venv/bin/activate && uvicorn app.main:app --reload --port 8000

frontend: ## Start Vite frontend (port 5173)
	cd frontend && npm run dev

# === Docker ===

up: ## Start all services via Docker Compose
	docker compose up -d
	@echo ""
	@echo "Backend:  http://localhost:8000"
	@echo "Frontend: http://localhost:5173"
	@echo "Neo4j:    http://localhost:7474"
	@echo "API Docs: http://localhost:8000/docs"

down: ## Stop all Docker services
	docker compose down

db: ## Start only databases (Neo4j, PostgreSQL, Redis)
	docker compose up -d neo4j postgres redis

logs: ## Tail Docker Compose logs
	docker compose logs -f

# === Testing ===

test: ## Run all tests
	cd backend && . .venv/bin/activate && pytest tests/ -v

test-cov: ## Run tests with coverage
	cd backend && . .venv/bin/activate && pytest tests/ --cov=app --cov-report=term-missing

lint: ## Lint and format check
	cd backend && . .venv/bin/activate && ruff check app/ tests/ && ruff format --check app/ tests/

fmt: ## Auto-format code
	cd backend && . .venv/bin/activate && ruff format app/ tests/

# === Data ===

demo: ## Load demo data into Neo4j
	cd backend && . .venv/bin/activate && python3 ../scripts/demo_data.py

# === Status ===

status: ## Check service health
	@curl -sf http://localhost:8000/health 2>/dev/null && echo "Backend:  UP" || echo "Backend:  DOWN"
	@curl -sf http://localhost:5173 >/dev/null 2>&1 && echo "Frontend: UP" || echo "Frontend: DOWN"
	@curl -sf http://localhost:7474 >/dev/null 2>&1 && echo "Neo4j:    UP" || echo "Neo4j:    DOWN"

# === Cleanup ===

clean: ## Remove build artifacts and caches
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .ruff_cache -exec rm -rf {} + 2>/dev/null || true
	rm -rf backend/.venv frontend/node_modules
