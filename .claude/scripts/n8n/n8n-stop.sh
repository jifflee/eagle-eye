#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: n8n-stop.sh
# Purpose: Stop local n8n instance
# Usage: ./scripts/n8n-stop.sh [--remove-volumes]
#
# Options:
#   --remove-volumes   Remove data volumes (WARNING: deletes all workflows!)
#   --help            Show this help message
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
REMOVE_VOLUMES=false

# Auto-detect repository name for per-repo container naming
if [ -z "$REPO_NAME" ]; then
  REPO_NAME=$(cd "$REPO_ROOT" && basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$REPO_ROOT")
  export REPO_NAME
fi

CONTAINER_NAME="n8n-${REPO_NAME}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-volumes)
      REMOVE_VOLUMES=true
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

# Check if n8n is running
check_running() {
  if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_info "n8n container is not running for repository: ${REPO_NAME}"
    return 1
  fi
  return 0
}

# Stop n8n
stop_n8n() {
  log_info "Stopping n8n..."

  if [ "$REMOVE_VOLUMES" = true ]; then
    log_warn "Removing volumes - all workflow data will be deleted!"
    docker compose -f "$COMPOSE_FILE" down -v
  else
    docker compose -f "$COMPOSE_FILE" down
  fi

  log_success "n8n stopped"
}

# Main
main() {
  log_info "n8n Shutdown Script"
  echo ""

  # Verify compose file exists
  if [ ! -f "$COMPOSE_FILE" ]; then
    die "Compose file not found: $COMPOSE_FILE"
  fi

  if check_running; then
    stop_n8n
  else
    # Still run docker compose down to clean up any orphaned resources
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
  fi

  if [ "$REMOVE_VOLUMES" = true ]; then
    log_info "Data volumes removed. Fresh start on next run."
  else
    log_info "Data preserved in volume 'n8n_${REPO_NAME}_data'"
    log_info "To remove data: ./scripts/n8n-stop.sh --remove-volumes"
  fi
}

main
