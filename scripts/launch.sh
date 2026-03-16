#!/usr/bin/env bash
set -euo pipefail

# === Port Discovery ===

find_open_port() {
  local preferred=$1
  local port=$preferred

  while lsof -i :"$port" >/dev/null 2>&1; do
    port=$((port + 1))
    if [ "$port" -gt $((preferred + 100)) ]; then
      echo "Could not find open port near $preferred" >&2
      exit 1
    fi
  done

  if [ "$port" -ne "$preferred" ]; then
    echo "  Port $preferred in use — using $port" >&2
  fi
  echo "$port"
}

# === Resolve Ports ===

echo ""
echo "  Resolving ports..."

BACKEND_PORT=$(find_open_port "${EAGLE_EYE_BACKEND_PORT:-8000}")
FRONTEND_PORT=$(find_open_port "${EAGLE_EYE_FRONTEND_PORT:-5173}")

export BACKEND_PORT
export FRONTEND_PORT
export BACKEND_URL="http://localhost:${BACKEND_PORT}"
export FRONTEND_URL="http://localhost:${FRONTEND_PORT}"

echo ""
echo "  Backend:  $BACKEND_URL"
echo "  Frontend: $FRONTEND_URL"
echo ""

# === Write .ports.env (consumed by Vite + backend) ===

PORTS_FILE="$(cd "$(dirname "$0")/.." && pwd)/.ports.env"
cat > "$PORTS_FILE" <<EOF
BACKEND_PORT=${BACKEND_PORT}
FRONTEND_PORT=${FRONTEND_PORT}
BACKEND_URL=${BACKEND_URL}
FRONTEND_URL=${FRONTEND_URL}
VITE_API_BASE_URL=${BACKEND_URL}
BACKEND_CORS_ORIGINS=${FRONTEND_URL}
EOF

# === Start Backend ===

echo "  Starting backend on port ${BACKEND_PORT}..."

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

(
  cd "$ROOT_DIR/backend"
  . .venv/bin/activate
  BACKEND_PORT="$BACKEND_PORT" \
  BACKEND_CORS_ORIGINS="$FRONTEND_URL" \
  uvicorn app.main:app --reload --port "$BACKEND_PORT" --host 0.0.0.0 \
    > /dev/null 2>&1
) &
BACKEND_PID=$!

# === Start Frontend ===

echo "  Starting frontend on port ${FRONTEND_PORT}..."

(
  cd "$ROOT_DIR/frontend"
  VITE_API_BASE_URL="$BACKEND_URL" \
  npm run dev -- --port "$FRONTEND_PORT" --strictPort \
    > /dev/null 2>&1
) &
FRONTEND_PID=$!

# === Wait for Ready ===

echo ""
echo "  Waiting for services..."

wait_for_port() {
  local port=$1
  local name=$2
  local attempts=0
  while ! curl -sf "http://localhost:${port}" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 30 ]; then
      echo "  ${name} failed to start on port ${port}" >&2
      return 1
    fi
    sleep 1
  done
  echo "  ${name} ready"
}

wait_for_port "$BACKEND_PORT" "Backend" &
wait_for_port "$FRONTEND_PORT" "Frontend" &
wait

# === Open Browser ===

echo ""
echo "  ================================================"
echo "  Eagle Eye running at: ${FRONTEND_URL}"
echo "  API docs at:          ${BACKEND_URL}/docs"
echo "  ================================================"
echo ""

# Open browser (macOS: open, Linux: xdg-open)
if command -v open >/dev/null 2>&1; then
  open "$FRONTEND_URL"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$FRONTEND_URL"
fi

echo "  Press Ctrl+C to stop"
echo ""

# === Cleanup on exit ===

cleanup() {
  echo ""
  echo "  Shutting down..."
  kill "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true
  rm -f "$PORTS_FILE"
  wait "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true
  echo "  Stopped."
}

trap cleanup INT TERM EXIT
wait
