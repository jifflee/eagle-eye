#!/usr/bin/env bash
set -euo pipefail

echo "=== Eagle Eye Development Setup ==="

# Check prerequisites
command -v docker >/dev/null 2>&1 || { echo "Docker is required. Install from https://docker.com"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Python 3.11+ is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Node.js 20+ is required"; exit 1; }

# Create .env from example if not exists
if [ ! -f .env ]; then
    cp .env.example .env
    echo "Created .env from .env.example"
fi

# Start infrastructure services
echo "Starting Neo4j, PostgreSQL, Redis..."
docker compose up -d neo4j postgres redis

# Wait for services
echo "Waiting for services to be healthy..."
sleep 10

# Backend setup
echo "Setting up backend..."
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
cd ..

# Frontend setup
echo "Setting up frontend..."
cd frontend
npm install
cd ..

# Load Neo4j schema
echo "Loading Neo4j schema..."
# Schema is loaded via demo_data.py which also creates indexes

# Load demo data
echo "Loading demo data..."
source backend/.venv/bin/activate
python3 scripts/demo_data.py

echo ""
echo "=== Setup Complete ==="
echo "Start backend:  cd backend && source .venv/bin/activate && uvicorn app.main:app --reload"
echo "Start frontend: cd frontend && npm run dev"
echo "Or run all:     docker compose up"
echo ""
echo "Backend:  http://localhost:8000"
echo "Frontend: http://localhost:5173"
echo "Neo4j:    http://localhost:7474"
echo "API Docs: http://localhost:8000/docs"
