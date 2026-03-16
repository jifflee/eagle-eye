#!/usr/bin/env bash
set -euo pipefail

# Resolve an open host port, scanning upward from the preferred port.
find_open_port() {
  local port=$1
  local max=$((port + 100))
  while lsof -i :"$port" >/dev/null 2>&1; do
    port=$((port + 1))
    if [ "$port" -gt "$max" ]; then
      echo "ERROR: Could not find open port near $1" >&2
      exit 1
    fi
  done
  echo "$port"
}

echo ""
echo "  Eagle Eye — Docker Compose"
echo ""
echo "  Resolving host ports..."

BACKEND_PORT=$(find_open_port "${BACKEND_PORT:-8000}")
FRONTEND_PORT=$(find_open_port "${FRONTEND_PORT:-5173}")
NEO4J_HTTP_PORT=$(find_open_port "${NEO4J_HTTP_PORT:-7474}")
NEO4J_BOLT_PORT=$(find_open_port "${NEO4J_BOLT_PORT:-7687}")
POSTGRES_PORT=$(find_open_port "${POSTGRES_PORT:-5432}")
REDIS_PORT=$(find_open_port "${REDIS_PORT:-6379}")

# Show what we picked (highlight changes)
show_port() {
  local name=$1 preferred=$2 actual=$3
  if [ "$preferred" -eq "$actual" ]; then
    printf "  %-12s %s\n" "$name" "$actual"
  else
    printf "  %-12s %s  (default %s was in use)\n" "$name" "$actual" "$preferred"
  fi
}

show_port "Backend"  8000 "$BACKEND_PORT"
show_port "Frontend" 5173 "$FRONTEND_PORT"
show_port "Neo4j"    7474 "$NEO4J_HTTP_PORT"
show_port "Bolt"     7687 "$NEO4J_BOLT_PORT"
show_port "Postgres" 5432 "$POSTGRES_PORT"
show_port "Redis"    6379 "$REDIS_PORT"

echo ""

# Export for docker compose
export BACKEND_PORT FRONTEND_PORT NEO4J_HTTP_PORT NEO4J_BOLT_PORT POSTGRES_PORT REDIS_PORT

# Run docker compose
docker compose up -d

echo ""
echo "  ================================================"
echo "  Frontend: http://localhost:${FRONTEND_PORT}"
echo "  API Docs: http://localhost:${BACKEND_PORT}/docs"
echo "  Neo4j:    http://localhost:${NEO4J_HTTP_PORT}"
echo "  ================================================"
echo ""

# Wait for frontend, then open browser
echo "  Waiting for services..."
attempts=0
while ! curl -sf "http://localhost:${FRONTEND_PORT}" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "$attempts" -gt 60 ]; then
    echo "  Timeout waiting for frontend. Check: docker compose logs"
    exit 1
  fi
  sleep 2
done

echo "  Ready!"
echo ""

if command -v open >/dev/null 2>&1; then
  open "http://localhost:${FRONTEND_PORT}"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "http://localhost:${FRONTEND_PORT}"
fi
