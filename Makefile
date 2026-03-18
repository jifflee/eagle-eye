.PHONY: help dev up down test demo status install backend frontend lint clean

# Default
help: ## Show this help
	@echo ""
	@echo "  Eagle Eye — OSINT Intelligence Platform"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

# === Guard: auto-install if deps missing ===

.venv-check:
	@if [ ! -d "backend/.venv" ]; then \
		echo "Backend venv not found — running install..."; \
		$(MAKE) install; \
	fi

.node-check:
	@if [ ! -d "frontend/node_modules" ]; then \
		echo "Frontend node_modules not found — running install..."; \
		$(MAKE) install; \
	fi

# === Setup ===

install: ## Install all dependencies (backend + frontend)
	@echo "Installing backend..."
	cd backend && python3 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]" -q
	@echo "Installing frontend..."
	cd frontend && npm install --silent
	@test -f .env || cp .env.example .env
	@echo "Done. Run 'make dev' to start."

# === Development ===

dev: .venv-check .node-check ## Start backend + frontend (auto-picks ports, opens browser)
	@bash scripts/launch.sh

backend: .venv-check ## Start FastAPI backend (specify port: BACKEND_PORT=9000 make backend)
	cd backend && . .venv/bin/activate && uvicorn app.main:app --reload \
		--port $${BACKEND_PORT:-8000} --host 0.0.0.0

frontend: .node-check ## Start Vite frontend (specify port: FRONTEND_PORT=3000 make frontend)
	cd frontend && VITE_API_BASE_URL="http://localhost:$${BACKEND_PORT:-8000}" \
		npm run dev -- --port $${FRONTEND_PORT:-5173}

# === Docker ===

up: ## Build, start all services, auto-pick ports, open browser
	@command -v docker >/dev/null 2>&1 || { echo "Docker is required. Install from https://docker.com"; exit 1; }
	@if [ ! -d "backend/.venv" ] || [ ! -d "frontend/node_modules" ]; then \
		echo "Dependencies not installed — running install first..."; \
		$(MAKE) install; \
	fi
	@test -f .env || cp .env.example .env
	docker compose build
	@bash scripts/docker-up.sh

down: ## Stop all Docker services
	docker compose down

rebuild: ## Rebuild containers from scratch and restart (preserves data)
	docker compose down --remove-orphans
	docker compose build --no-cache
	@test -f .env || cp .env.example .env
	@echo "Data volumes preserved (Neo4j, PostgreSQL, Redis)"
	@bash scripts/docker-up.sh

nuke: ## WARNING: Delete everything including all stored data
	@echo "This will DELETE all investigation data, users, and cached results."
	@read -p "Backup first? [Y/n] " backup; \
	if [ "$$backup" != "n" ] && [ "$$backup" != "N" ]; then \
		bash scripts/backup.sh; \
	fi
	@read -p "Proceed with DELETE? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	docker compose down -v --remove-orphans
	@echo "All containers stopped and data volumes deleted."

backup: ## Backup PostgreSQL, Neo4j, and Redis data
	@bash scripts/backup.sh

backup-setup: ## Install automatic backup every 6 hours via cron
	@bash scripts/backup-scheduled.sh --setup

db: ## Start only databases (Neo4j, PostgreSQL, Redis)
	@bash -c '\
		find_port() { local p=$$1; while lsof -i :$$p >/dev/null 2>&1; do p=$$((p+1)); done; echo $$p; }; \
		export NEO4J_HTTP_PORT=$$(find_port 7474); \
		export NEO4J_BOLT_PORT=$$(find_port 7687); \
		export POSTGRES_PORT=$$(find_port 5432); \
		export REDIS_PORT=$$(find_port 6379); \
		echo "  Neo4j:    localhost:$$NEO4J_HTTP_PORT"; \
		echo "  Bolt:     localhost:$$NEO4J_BOLT_PORT"; \
		echo "  Postgres: localhost:$$POSTGRES_PORT"; \
		echo "  Redis:    localhost:$$REDIS_PORT"; \
		docker compose up -d neo4j postgres redis \
	'

logs: ## Tail Docker Compose logs
	docker compose logs -f

# === Testing ===

test: .venv-check ## Run all backend tests
	cd backend && . .venv/bin/activate && pytest tests/ -v

test-cov: .venv-check ## Run tests with coverage
	cd backend && . .venv/bin/activate && pytest tests/ --cov=app --cov-report=term-missing

test-e2e: .node-check ## Run Playwright E2E tests
	cd frontend && npx playwright test

test-e2e-headed: .node-check ## Run E2E tests in visible browser
	cd frontend && npx playwright test --headed

test-e2e-ui: .node-check ## Open Playwright interactive UI
	cd frontend && npx playwright test --ui

test-all: test test-e2e ## Run all tests (backend + E2E)

lint: .venv-check ## Lint and format check
	cd backend && . .venv/bin/activate && ruff check app/ tests/ && ruff format --check app/ tests/

fmt: .venv-check ## Auto-format code
	cd backend && . .venv/bin/activate && ruff format app/ tests/

# === Data ===

demo: .venv-check ## Load demo data into Neo4j
	cd backend && . .venv/bin/activate && python3 ../scripts/demo_data.py

# === Status ===

status: ## Check service health
	@echo "Checking services..."
	@for port in 8000 8001 8002; do \
		if curl -sf "http://localhost:$$port/health" >/dev/null 2>&1; then \
			echo "  Backend:  http://localhost:$$port (UP)"; \
			break; \
		fi; \
	done || echo "  Backend:  DOWN"
	@for port in 5173 5174 5175 3000; do \
		if curl -sf "http://localhost:$$port" >/dev/null 2>&1; then \
			echo "  Frontend: http://localhost:$$port (UP)"; \
			break; \
		fi; \
	done || echo "  Frontend: DOWN"
	@curl -sf http://localhost:7474 >/dev/null 2>&1 && echo "  Neo4j:    http://localhost:7474 (UP)" || echo "  Neo4j:    DOWN"

# === Cleanup ===

clean: ## Remove build artifacts and caches
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .ruff_cache -exec rm -rf {} + 2>/dev/null || true
	rm -f .ports.env
	rm -rf backend/.venv frontend/node_modules
