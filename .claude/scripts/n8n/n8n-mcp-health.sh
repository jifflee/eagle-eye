#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: n8n-mcp-health.sh
# Purpose: Check and repair n8n-mcp MCP server health
# Usage: ./scripts/n8n-mcp-health.sh [--repair] [--json] [--quiet]
#
# Options:
#   --repair   Attempt to fix issues (clears corrupted npx cache)
#   --json     Output JSON format (for integration with other scripts)
#   --quiet    Minimal output (exit code only)
#   --help     Show this help message
#
# Exit codes:
#   0 - n8n-mcp is healthy
#   1 - n8n-mcp is unhealthy
#   2 - Invalid arguments
#   3 - Repair attempted but failed
#
# Dependencies: node, npm, npx
# Issue: #521 - Fix n8n MCP deployment failure in Claude
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
JSON_OUTPUT=false
QUIET=false
REPAIR=false
TIMEOUT=15  # seconds

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repair)
      REPAIR=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --quiet)
      QUIET=true
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
  local node_version="$2"
  local npx_available="$3"
  local n8n_mcp_exists="$4"
  local n8n_mcp_starts="$5"
  local issue="$6"
  local repair_status="$7"

  jq -n \
    --argjson healthy "$healthy" \
    --arg node_version "$node_version" \
    --argjson npx_available "$npx_available" \
    --argjson n8n_mcp_exists "$n8n_mcp_exists" \
    --argjson n8n_mcp_starts "$n8n_mcp_starts" \
    --arg issue "$issue" \
    --arg repair_status "$repair_status" \
    --arg checked_at "$(timestamp)" \
    '{
      healthy: $healthy,
      node_version: $node_version,
      npx_available: $npx_available,
      n8n_mcp_exists: $n8n_mcp_exists,
      n8n_mcp_starts: $n8n_mcp_starts,
      issue: $issue,
      repair_status: $repair_status,
      checked_at: $checked_at
    }'
}

# Check Node.js is installed
check_node() {
  if command -v node &>/dev/null; then
    node --version 2>/dev/null || echo "unknown"
    return 0
  fi
  return 1
}

# Check npx is available
check_npx() {
  if command -v npx &>/dev/null; then
    return 0
  fi
  return 1
}

# Check if n8n-mcp package exists on npm
check_n8n_mcp_exists() {
  npm view n8n-mcp version &>/dev/null
}

# Check if n8n-mcp starts successfully
check_n8n_mcp_starts() {
  local output
  output=$(timeout "$TIMEOUT" npx n8n-mcp --help 2>&1) || true

  # Check for successful server start indicators
  if echo "$output" | grep -q "MCP server initialized" || echo "$output" | grep -q "Server running"; then
    return 0
  fi

  # Check for common errors
  if echo "$output" | grep -q "Cannot find module"; then
    echo "MODULE_NOT_FOUND"
    return 1
  fi

  if echo "$output" | grep -q "ENOENT"; then
    echo "FILE_NOT_FOUND"
    return 1
  fi

  # Unknown error
  echo "UNKNOWN_ERROR"
  return 1
}

# Find and clear corrupted npx cache for n8n-mcp
repair_npx_cache() {
  local npx_cache_dir="$HOME/.npm/_npx"

  if [ ! -d "$npx_cache_dir" ]; then
    log_warn "npx cache directory not found"
    return 1
  fi

  # Find directories containing n8n-mcp
  local cleared=0
  while IFS= read -r -d '' dir; do
    if [ -d "$dir/node_modules/n8n-mcp" ]; then
      log_info "Clearing corrupted cache: $dir"
      rm -rf "$dir"
      cleared=$((cleared + 1))
    fi
  done < <(find "$npx_cache_dir" -maxdepth 1 -type d -print0 2>/dev/null)

  if [ "$cleared" -gt 0 ]; then
    log_info "Cleared $cleared cached directories"
    return 0
  else
    log_warn "No n8n-mcp cache found to clear"
    return 1
  fi
}

# Reinstall n8n-mcp to validate fix
verify_repair() {
  log_info "Verifying repair by testing n8n-mcp..."
  if check_n8n_mcp_starts >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Main
main() {
  local node_version=""
  local npx_available=false
  local n8n_mcp_exists=false
  local n8n_mcp_starts=false
  local issue=""
  local repair_status=""
  local healthy=false

  # Check Node.js
  node_version=$(check_node 2>/dev/null || echo "not installed")
  if [ "$node_version" = "not installed" ]; then
    issue="Node.js not installed"
  fi

  # Check npx
  if check_npx; then
    npx_available=true
  else
    issue="npx not available"
  fi

  # Check n8n-mcp package exists
  if [ "$npx_available" = true ]; then
    if check_n8n_mcp_exists; then
      n8n_mcp_exists=true
    else
      issue="n8n-mcp package not found on npm"
    fi
  fi

  # Check if n8n-mcp starts successfully
  if [ "$n8n_mcp_exists" = true ]; then
    local start_result
    start_result=$(check_n8n_mcp_starts 2>&1)
    local start_exit=$?

    if [ $start_exit -eq 0 ]; then
      n8n_mcp_starts=true
    else
      n8n_mcp_starts=false
      case "$start_result" in
        MODULE_NOT_FOUND)
          issue="Corrupted npx cache: missing module (run with --repair)"
          ;;
        FILE_NOT_FOUND)
          issue="Corrupted npx cache: missing files (run with --repair)"
          ;;
        *)
          issue="n8n-mcp failed to start: $start_result"
          ;;
      esac
    fi
  fi

  # Attempt repair if requested
  if [ "$REPAIR" = true ] && [ "$n8n_mcp_starts" = false ] && [ -n "$issue" ]; then
    if [ "$QUIET" = false ] && [ "$JSON_OUTPUT" = false ]; then
      log_info "Attempting repair..."
    fi

    if repair_npx_cache; then
      if verify_repair; then
        repair_status="success"
        n8n_mcp_starts=true
        issue=""
      else
        repair_status="failed"
      fi
    else
      repair_status="no_cache_found"
    fi
  fi

  # Determine overall health
  if [ "$npx_available" = true ] && [ "$n8n_mcp_exists" = true ] && [ "$n8n_mcp_starts" = true ]; then
    healthy=true
  fi

  # Output results
  if [ "$JSON_OUTPUT" = true ]; then
    output_json "$healthy" "$node_version" "$npx_available" "$n8n_mcp_exists" "$n8n_mcp_starts" "$issue" "$repair_status"
  elif [ "$QUIET" = false ]; then
    echo "n8n-mcp Health Check"
    echo "===================="
    echo ""
    if [ "$healthy" = true ]; then
      log_success "n8n-mcp is healthy"
    else
      log_error "n8n-mcp is unhealthy"
    fi
    echo ""
    echo "  Node.js:     $node_version"
    echo "  npx:         $([ "$npx_available" = true ] && echo "available" || echo "not available")"
    echo "  Package:     $([ "$n8n_mcp_exists" = true ] && echo "exists on npm" || echo "not found")"
    echo "  Starts:      $([ "$n8n_mcp_starts" = true ] && echo "yes" || echo "no")"
    if [ -n "$issue" ]; then
      echo "  Issue:       $issue"
    fi
    if [ -n "$repair_status" ]; then
      echo "  Repair:      $repair_status"
    fi
    echo ""

    if [ "$healthy" = false ] && [ -z "$repair_status" ]; then
      echo "To attempt automatic repair, run:"
      echo "  ./scripts/n8n-mcp-health.sh --repair"
      echo ""
    fi
  fi

  # Exit code based on health
  if [ "$healthy" = true ]; then
    exit 0
  elif [ "$repair_status" = "failed" ]; then
    exit 3
  else
    exit 1
  fi
}

main
