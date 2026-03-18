#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: n8n-start.sh
# Purpose: Start local n8n instance via Docker Desktop
# Usage: ./scripts/n8n-start.sh [--detach] [--wait]
#
# Options:
#   --detach    Run in background (default)
#   --foreground   Run in foreground (attach to logs)
#   --wait      Wait for health check to pass (default: 60s)
#   --help      Show this help message
#
# Dependencies: docker, docker compose
# Issue: #427 - Deploy local n8n instance via Docker Desktop
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source common utilities
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  source "$SCRIPT_DIR/lib/common.sh"
else
  # Minimal fallback
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_success() { echo "[OK] $*" >&2; }
  die() { log_error "$*"; exit 1; }
fi

# Configuration
COMPOSE_FILE="$REPO_ROOT/deploy/n8n/docker-compose.n8n.yml"
N8N_PORT="${N8N_PORT:-5678}"
N8N_URL="http://localhost:$N8N_PORT"
HEALTH_TIMEOUT=60
DETACH=true

# Auto-detect repository name for per-repo container naming
if [ -z "$REPO_NAME" ]; then
  REPO_NAME=$(cd "$REPO_ROOT" && basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$REPO_ROOT")
  export REPO_NAME
fi

CONTAINER_NAME="n8n-${REPO_NAME}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --detach)
      DETACH=true
      shift
      ;;
    --foreground)
      DETACH=false
      shift
      ;;
    --wait)
      WAIT_FOR_HEALTH=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# Check prerequisites
check_docker() {
  if ! command -v docker &>/dev/null; then
    die "Docker is not installed. Please install Docker Desktop."
  fi

  if ! docker info &>/dev/null; then
    die "Docker daemon is not running. Please start Docker Desktop."
  fi

  log_success "Docker is available"
}

# Check for docker compose (v2)
check_compose() {
  if ! docker compose version &>/dev/null; then
    die "docker compose (v2) is not available. Please update Docker."
  fi

  log_success "Docker Compose is available"
}

# Check if n8n is already running
check_existing() {
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_warn "n8n container is already running for repository: ${REPO_NAME}"
    log_info "Access n8n at: $N8N_URL"
    exit 0
  fi
}

# Validate version pinning
validate_version() {
  log_info "Validating n8n version pinning..."

  # Get pinned version from docker-compose file
  local pinned_version
  pinned_version=$(grep -E "image:.*n8n" "$COMPOSE_FILE" | sed 's/.*://g' | tr -d ' ' || echo "")

  if [ -z "$pinned_version" ]; then
    log_warn "Could not extract pinned version from $COMPOSE_FILE"
    return 0
  fi

  # Check if using 'latest' tag (not allowed)
  if [ "$pinned_version" = "latest" ]; then
    log_error "Version pinning validation failed!"
    echo ""
    echo "The docker-compose.n8n.yml file uses 'latest' tag, which is not allowed."
    echo "Please pin to a specific version for reproducibility."
    echo ""
    echo "Example: image: docker.n8n.io/n8nio/n8n:1.76.1"
    echo ""
    exit 1
  fi

  log_success "Version pinned to: $pinned_version"

  # If container is already running, check if it matches the pinned version
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    local running_version
    running_version=$(docker exec "$CONTAINER_NAME" n8n --version 2>/dev/null | head -1 || echo "")

    if [ -n "$running_version" ]; then
      if echo "$running_version" | grep -q "$pinned_version"; then
        log_success "Running version matches pinned version"
      else
        log_warn "Version mismatch detected:"
        log_warn "  Pinned:  $pinned_version"
        log_warn "  Running: $running_version"
        echo ""
        echo "Recommendation:"
        echo "  - Stop and restart n8n to use the pinned version:"
        echo "    ./scripts/n8n-stop.sh"
        echo "    ./scripts/n8n-start.sh"
        echo ""
      fi
    fi
  fi
}

# Start n8n
start_n8n() {
  log_info "Starting n8n..."

  if [ "$DETACH" = true ]; then
    docker compose -f "$COMPOSE_FILE" up -d
  else
    docker compose -f "$COMPOSE_FILE" up
    return  # Don't continue if running in foreground
  fi
}

# Wait for health check
wait_for_health() {
  log_info "Waiting for n8n to be healthy (timeout: ${HEALTH_TIMEOUT}s)..."

  local count=0
  while [ $count -lt $HEALTH_TIMEOUT ]; do
    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
      die "n8n container stopped unexpectedly. Check logs with: docker logs ${CONTAINER_NAME}"
    fi

    # Check health endpoint
    if curl -sf "$N8N_URL/healthz" &>/dev/null; then
      log_success "n8n is healthy!"
      return 0
    fi

    sleep 2
    count=$((count + 2))
    printf "."
  done

  echo ""
  log_error "n8n failed to become healthy within ${HEALTH_TIMEOUT}s"
  log_info "Check logs with: docker logs ${CONTAINER_NAME}"
  exit 1
}

# Print success message
print_success() {
  echo ""
  log_success "n8n is running!"
  echo ""
  echo "  Repository: ${REPO_NAME}"
  echo "  Container:  ${CONTAINER_NAME}"
  echo "  UI:         $N8N_URL"
  echo "  Health:     $N8N_URL/healthz"
  echo "  Webhooks:   $N8N_URL/webhook/<workflow-path>"
  echo ""
  echo "Commands:"
  echo "  Stop:      ./scripts/n8n-stop.sh"
  echo "  Logs:      docker logs -f ${CONTAINER_NAME}"
  echo "  Health:    ./scripts/n8n-health.sh"
  echo ""
}

# Main
main() {
  log_info "n8n Deployment Script"
  echo ""

  check_docker
  check_compose
  check_existing

  # Verify compose file exists
  if [ ! -f "$COMPOSE_FILE" ]; then
    die "Compose file not found: $COMPOSE_FILE"
  fi

  # Validate version pinning before starting
  validate_version

  start_n8n

  # Wait for health if detached
  if [ "$DETACH" = true ]; then
    wait_for_health
    print_success
  fi
}

main
