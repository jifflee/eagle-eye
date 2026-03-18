#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: n8n-health.sh
# Purpose: Check health of local n8n instance
# Usage: ./scripts/n8n-health.sh [--json]
#
# Options:
#   --json              Output JSON format (for integration with other scripts)
#   --quiet             Minimal output (exit code only)
#   --include-workflows Include workflow health checks (default: container only)
#   --help              Show this help message
#
# Exit codes:
#   0 - n8n is healthy (and workflows if checked)
#   1 - n8n is unhealthy or not running (or workflows unhealthy)
#   2 - Invalid arguments
#
# Dependencies: docker, curl, jq
# Issue: #427 - Deploy local n8n instance via Docker Desktop
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  source "$SCRIPT_DIR/lib/common.sh"
else
  # Minimal fallback
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_success() { echo "[OK] $*" >&2; }
  timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fi

# Configuration
N8N_PORT="${N8N_PORT:-5678}"
N8N_URL="http://localhost:$N8N_PORT"
JSON_OUTPUT=false
QUIET=false
INCLUDE_WORKFLOWS=false

# Auto-detect repository name for per-repo container naming (matches n8n-start.sh)
if [ -z "$REPO_NAME" ]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  REPO_NAME=$(cd "$REPO_ROOT" && basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$REPO_ROOT")
fi
CONTAINER_NAME="n8n-${REPO_NAME:-local}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    --include-workflows)
      INCLUDE_WORKFLOWS=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Output JSON result
output_json() {
  local healthy="$1"
  local container_running="$2"
  local health_endpoint="$3"
  local container_status="$4"
  local uptime="$5"

  jq -n \
    --argjson healthy "$healthy" \
    --argjson container_running "$container_running" \
    --argjson health_endpoint "$health_endpoint" \
    --arg container_status "$container_status" \
    --arg uptime "$uptime" \
    --arg url "$N8N_URL" \
    --arg checked_at "$(timestamp)" \
    '{
      healthy: $healthy,
      container_running: $container_running,
      health_endpoint: $health_endpoint,
      container_status: $container_status,
      uptime: $uptime,
      url: $url,
      checked_at: $checked_at
    }'
}

# Check if n8n container is running
check_container() {
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    return 0
  fi
  return 1
}

# Get container status
get_container_status() {
  docker inspect --format='{{.State.Status}}' ${CONTAINER_NAME} 2>/dev/null || echo "not found"
}

# Get container uptime
get_container_uptime() {
  local started_at
  started_at=$(docker inspect --format='{{.State.StartedAt}}' ${CONTAINER_NAME} 2>/dev/null)
  if [ -n "$started_at" ] && [ "$started_at" != "0001-01-01T00:00:00Z" ]; then
    # Calculate rough uptime
    local started_epoch now_epoch diff_seconds
    if date --version >/dev/null 2>&1; then
      # GNU date
      started_epoch=$(date -u -d "$started_at" +%s 2>/dev/null || echo 0)
    else
      # BSD date (macOS)
      started_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${started_at%.*}" +%s 2>/dev/null || echo 0)
    fi
    now_epoch=$(date -u +%s)

    if [ "$started_epoch" -gt 0 ]; then
      diff_seconds=$((now_epoch - started_epoch))
      local hours=$((diff_seconds / 3600))
      local minutes=$(((diff_seconds % 3600) / 60))
      local seconds=$((diff_seconds % 60))
      printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
      return
    fi
  fi
  echo "unknown"
}

# Check health endpoint
check_health_endpoint() {
  if curl -sf "$N8N_URL/healthz" &>/dev/null; then
    return 0
  fi
  return 1
}

# Main
main() {
  local container_running=false
  local health_endpoint=false
  local container_status="not found"
  local uptime="N/A"
  local healthy=false
  local workflow_health_status=""
  local workflows_healthy=true

  # Check container
  if check_container; then
    container_running=true
    container_status=$(get_container_status)
    uptime=$(get_container_uptime)
  fi

  # Check health endpoint (only if container is running)
  if [ "$container_running" = true ]; then
    if check_health_endpoint; then
      health_endpoint=true
    fi
  fi

  # Determine overall health
  if [ "$container_running" = true ] && [ "$health_endpoint" = true ]; then
    healthy=true
  fi

  # Check workflow health if requested (only if container is healthy)
  if [ "$INCLUDE_WORKFLOWS" = true ] && [ "$healthy" = true ]; then
    local workflow_script="${SCRIPT_DIR}/n8n-workflow-health.sh"
    if [ -x "$workflow_script" ]; then
      if [ "$JSON_OUTPUT" = true ]; then
        # Get workflow health as JSON
        workflow_health_status=$("$workflow_script" --json 2>/dev/null || echo '{"healthy": false, "error": "workflow check failed"}')
        workflows_healthy=$(echo "$workflow_health_status" | jq -r '.healthy // false')
      elif [ "$QUIET" = false ]; then
        # Run workflow health check (will print its own output)
        echo ""
        if ! "$workflow_script" 2>/dev/null; then
          workflows_healthy=false
        fi
      else
        # Quiet mode - just check exit code
        if ! "$workflow_script" --quiet 2>/dev/null; then
          workflows_healthy=false
        fi
      fi

      # Update overall health based on workflows
      if [ "$workflows_healthy" = false ]; then
        healthy=false
      fi
    else
      if [ "$QUIET" = false ] && [ "$JSON_OUTPUT" = false ]; then
        log_warn "Workflow health check script not found, skipping workflow checks"
      fi
    fi
  fi

  # Output results
  if [ "$JSON_OUTPUT" = true ]; then
    # Build JSON output with optional workflow data
    if [ -n "$workflow_health_status" ]; then
      # Merge container health and workflow health
      jq -n \
        --argjson container_health "$(output_json "$healthy" "$container_running" "$health_endpoint" "$container_status" "$uptime")" \
        --argjson workflow_health "$workflow_health_status" \
        '{
          healthy: ($container_health.healthy and $workflow_health.healthy),
          container: $container_health,
          workflows: $workflow_health,
          checked_at: (now | todate)
        }'
    else
      output_json "$healthy" "$container_running" "$health_endpoint" "$container_status" "$uptime"
    fi
  elif [ "$QUIET" = false ]; then
    echo "n8n Health Check"
    echo "================"
    echo ""
    if [ "$healthy" = true ]; then
      log_success "n8n is healthy"
    else
      log_error "n8n is unhealthy"
    fi
    echo ""
    echo "  Container: $([ "$container_running" = true ] && echo "running" || echo "not running")"
    echo "  Status:    $container_status"
    echo "  Uptime:    $uptime"
    echo "  Health:    $([ "$health_endpoint" = true ] && echo "responding" || echo "not responding")"
    echo "  URL:       $N8N_URL"

    if [ "$INCLUDE_WORKFLOWS" = true ]; then
      if [ "$workflows_healthy" = true ]; then
        echo "  Workflows: healthy"
      else
        echo "  Workflows: unhealthy (see details above)"
      fi
    fi
    echo ""
  fi

  # Exit code based on health
  if [ "$healthy" = true ]; then
    exit 0
  else
    exit 1
  fi
}

main
