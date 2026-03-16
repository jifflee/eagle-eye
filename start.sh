#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "  _____ _    ____ _     _____   _______   _______ "
echo " | ____/ \  / ___| |   | ____| | ____\ \ / / ____|"
echo " |  _|/ _ \| |  _| |   |  _|   |  _|  \ V /|  _|  "
echo " | |_/ ___ \ |_| | |___| |___  | |___  | | | |___ "
echo " |___/_/   \_\____|_____|_____| |_____| |_| |_____|"
echo -e "${NC}"
echo -e "${GREEN}Open Source Intelligence Platform${NC}"
echo ""

MODE="${1:-help}"

case "$MODE" in
  docker|up)
    echo -e "${CYAN}Starting all services via Docker Compose...${NC}"
    docker compose up -d
    echo ""
    echo -e "${GREEN}Services running:${NC}"
    echo "  Backend:  http://localhost:8000"
    echo "  API Docs: http://localhost:8000/docs"
    echo "  Frontend: http://localhost:5173"
    echo "  Neo4j:    http://localhost:7474"
    echo ""
    echo -e "${YELLOW}Logs: docker compose logs -f${NC}"
    echo -e "${YELLOW}Stop: docker compose down${NC}"
    ;;

  dev)
    echo -e "${CYAN}Starting development mode (local Python + Node)...${NC}"
    echo ""

    # Check prerequisites
    command -v python3 >/dev/null 2>&1 || { echo -e "${RED}Python 3.11+ required${NC}"; exit 1; }
    command -v node >/dev/null 2>&1 || { echo -e "${RED}Node.js 20+ required${NC}"; exit 1; }

    # Start infrastructure
    echo -e "${YELLOW}[1/4] Starting databases (Neo4j, PostgreSQL, Redis)...${NC}"
    docker compose up -d neo4j postgres redis 2>/dev/null || echo -e "${YELLOW}Docker not available — make sure databases are running manually${NC}"
    sleep 3

    # Backend
    echo -e "${YELLOW}[2/4] Setting up backend...${NC}"
    if [ ! -d "backend/.venv" ]; then
      python3 -m venv backend/.venv
      source backend/.venv/bin/activate
      pip install -e "backend/.[dev]" -q
    else
      source backend/.venv/bin/activate
    fi

    # Create .env if missing
    if [ ! -f ".env" ]; then
      cp .env.example .env
      echo -e "${YELLOW}Created .env from .env.example — edit with your settings${NC}"
    fi

    echo -e "${YELLOW}[3/4] Starting backend (port 8000)...${NC}"
    cd backend
    uvicorn app.main:app --reload --port 8000 &
    BACKEND_PID=$!
    cd ..

    # Frontend
    echo -e "${YELLOW}[4/4] Starting frontend (port 5173)...${NC}"
    if [ ! -d "frontend/node_modules" ]; then
      cd frontend && npm install -q && cd ..
    fi
    cd frontend
    npm run dev &
    FRONTEND_PID=$!
    cd ..

    echo ""
    echo -e "${GREEN}Eagle Eye is running:${NC}"
    echo "  Backend:  http://localhost:8000"
    echo "  API Docs: http://localhost:8000/docs"
    echo "  Frontend: http://localhost:5173"
    echo ""
    echo -e "${YELLOW}Press Ctrl+C to stop all services${NC}"

    # Trap Ctrl+C
    trap "echo ''; echo 'Shutting down...'; kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; exit 0" INT TERM
    wait
    ;;

  test)
    echo -e "${CYAN}Running tests...${NC}"
    echo ""
    echo -e "${YELLOW}Backend tests:${NC}"
    cd backend
    if [ ! -d ".venv" ]; then
      python3 -m venv .venv
      source .venv/bin/activate
      pip install -e ".[dev]" -q
    else
      source .venv/bin/activate
    fi
    pytest tests/ -v
    cd ..
    echo ""
    echo -e "${YELLOW}Frontend tests:${NC}"
    cd frontend
    if [ ! -d "node_modules" ]; then
      npm install -q
    fi
    npm test 2>/dev/null || echo -e "${YELLOW}No frontend tests configured yet${NC}"
    ;;

  demo)
    echo -e "${CYAN}Loading demo data into Neo4j...${NC}"
    source backend/.venv/bin/activate 2>/dev/null || {
      python3 -m venv backend/.venv
      source backend/.venv/bin/activate
      pip install -e "backend/.[dev]" -q
    }
    python3 scripts/demo_data.py
    ;;

  stop|down)
    echo -e "${CYAN}Stopping all services...${NC}"
    docker compose down 2>/dev/null || true
    pkill -f "uvicorn app.main" 2>/dev/null || true
    pkill -f "vite" 2>/dev/null || true
    echo -e "${GREEN}All services stopped.${NC}"
    ;;

  status)
    echo -e "${CYAN}Service status:${NC}"
    echo ""
    # Check backend
    if curl -s http://localhost:8000/health > /dev/null 2>&1; then
      HEALTH=$(curl -s http://localhost:8000/health)
      echo -e "  Backend:  ${GREEN}running${NC} — $HEALTH"
    else
      echo -e "  Backend:  ${RED}not running${NC}"
    fi
    # Check frontend
    if curl -s http://localhost:5173 > /dev/null 2>&1; then
      echo -e "  Frontend: ${GREEN}running${NC}"
    else
      echo -e "  Frontend: ${RED}not running${NC}"
    fi
    # Check Neo4j
    if curl -s http://localhost:7474 > /dev/null 2>&1; then
      echo -e "  Neo4j:    ${GREEN}running${NC}"
    else
      echo -e "  Neo4j:    ${RED}not running${NC}"
    fi
    # Check PostgreSQL
    if pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
      echo -e "  Postgres: ${GREEN}running${NC}"
    else
      echo -e "  Postgres: ${RED}not running${NC}"
    fi
    # Check Redis
    if redis-cli ping > /dev/null 2>&1; then
      echo -e "  Redis:    ${GREEN}running${NC}"
    else
      echo -e "  Redis:    ${RED}not running${NC}"
    fi
    ;;

  *)
    echo "Usage: ./start.sh <command>"
    echo ""
    echo "Commands:"
    echo "  dev      Start in development mode (local Python + Node)"
    echo "  docker   Start all services via Docker Compose"
    echo "  test     Run all tests (backend + frontend)"
    echo "  demo     Load demo data into Neo4j"
    echo "  status   Check if services are running"
    echo "  stop     Stop all services"
    echo ""
    echo "Quick start:"
    echo "  ./start.sh dev       # First time setup + start"
    echo "  ./start.sh docker    # Or use Docker for everything"
    ;;
esac
