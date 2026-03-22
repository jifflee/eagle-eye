.PHONY: help install dev up down rebuild nuke backup test test-e2e test-all lint fmt demo status logs clean

help: ## Show available commands
	@echo ""
	@echo "  Eagle Eye — OSINT Intelligence Platform"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""

# === Setup ===

install: ## Install backend + frontend dependencies
	@echo "Backend..." && cd backend && python3 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]" -q
	@echo "Frontend..." && cd frontend && npm install --silent
	@test -f .env || cp .env.example .env
	@echo "Done. Run 'make dev' or 'make up'."

# === Run ===

dev: ## Start locally (auto-picks ports, opens browser)
	@test -d backend/.venv || $(MAKE) install
	@bash scripts/launch.sh

up: ## Start via Docker (builds, auto-picks ports, opens browser)
	@test -f .env || cp .env.example .env
	@docker compose build -q && bash scripts/docker-up.sh

down: ## Stop Docker services
	@docker compose down

rebuild: ## Full clean rebuild (preserves data)
	@docker compose down --remove-orphans
	@echo "Building images (no cache)..."
	@docker compose build --no-cache
	@echo "Build complete. Data preserved." && bash scripts/docker-up.sh

nuke: ## DELETE all data (with backup prompt)
	@echo "This will DELETE all data." && read -p "Backup first? [Y/n] " b; \
	[ "$$b" = "n" ] || [ "$$b" = "N" ] || bash scripts/backup.sh
	@read -p "DELETE all data? [y/N] " c && [ "$$c" = "y" ] || exit 1
	@docker compose down -v --remove-orphans && echo "Deleted."

# === Test ===

test: ## Run backend tests
	@cd backend && . .venv/bin/activate && pytest tests/ -v

test-e2e: ## Run Playwright E2E tests
	@cd frontend && npx playwright test

test-all: test test-e2e ## Run all tests

lint: ## Lint + format check
	@cd backend && . .venv/bin/activate && ruff check app/ tests/ && ruff format --check app/ tests/

fmt: ## Auto-format code
	@cd backend && . .venv/bin/activate && ruff format app/ tests/

# === Data ===

backup: ## Backup all databases
	@bash scripts/backup.sh

demo: ## Load demo data into Neo4j
	@cd backend && . .venv/bin/activate && python3 ../scripts/demo_data.py

# === Info ===

status: ## Show running services and URLs
	@docker compose ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Docker not running"

logs: ## Tail all Docker logs
	@docker compose logs -f

clean: ## Remove caches and installed deps
	@find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; true
	@rm -rf backend/.venv frontend/node_modules .ports.env
	@echo "Cleaned."
