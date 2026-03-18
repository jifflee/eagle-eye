#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: n8n-export-config.sh
# Purpose: Export n8n workflows to n8n-workflows/ for version control
# Usage: ./scripts/n8n-export-config.sh [--diff] [--force]
#
# Options:
#   --diff      Show what changed without exporting
#   --force     Force export even if no changes detected
#   --help      Show this help message
#
# Features:
#   - Exports all workflows from n8n to n8n-workflows/
#   - Exports credential structure (no secret values)
#   - Uses consistent naming: {workflow-name}.json (slugified)
#   - Detects changes: only overwrites if workflow has been modified
#   - Exports settings and metadata
#
# Dependencies: curl, jq
# Issue: #725 - n8n config backup: export/import workflows to repo for version control
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
WORKFLOWS_DIR="$REPO_ROOT/n8n-workflows"
ENV_LOCAL="$REPO_ROOT/.env.local"
N8N_PORT="${N8N_PORT:-5678}"
N8N_URL="http://localhost:$N8N_PORT"
DIFF_MODE=false
FORCE_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff)
      DIFF_MODE=true
      shift
      ;;
    --force)
      FORCE_MODE=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      die "Unknown option: $1. Use --help for usage information."
      ;;
  esac
done

# Load environment variables
if [ -f "$ENV_LOCAL" ]; then
  set -a
  source "$ENV_LOCAL"
  set +a
fi

# Check prerequisites
check_prerequisites() {
  log_info "Checking prerequisites..."

  if ! command -v curl &>/dev/null; then
    die "curl is not installed. Please install curl."
  fi

  if ! command -v jq &>/dev/null; then
    die "jq is not installed. Please install jq."
  fi

  # Check for N8N_API_KEY
  if [ -z "${N8N_API_KEY:-}" ]; then
    die "N8N_API_KEY not found in environment. Please set it in .env.local or run n8n-setup.sh"
  fi

  log_success "Prerequisites met"
}

# Check if n8n is running
check_n8n_running() {
  log_info "Checking n8n connectivity..."

  if ! curl -sf "$N8N_URL/healthz" &>/dev/null; then
    die "n8n is not running or not accessible at $N8N_URL. Please start n8n with: ./scripts/n8n-start.sh"
  fi

  log_success "n8n is running at $N8N_URL"
}

# Slugify workflow name for filename
slugify() {
  local name="$1"
  echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
}

# Fetch all workflows from n8n
fetch_workflows() {
  log_info "Fetching workflows from n8n..."

  local response
  response=$(curl -sf "$N8N_URL/api/v1/workflows" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" 2>/dev/null || echo "")

  if [ -z "$response" ]; then
    die "Failed to fetch workflows from n8n API"
  fi

  if ! echo "$response" | jq -e '.data' &>/dev/null; then
    log_error "API response:"
    echo "$response" | jq . 2>/dev/null || echo "$response"
    die "Invalid API response from n8n"
  fi

  echo "$response"
}

# Export a single workflow
export_workflow() {
  local workflow_id="$1"
  local workflow_name="$2"
  local workflow_data="$3"

  # Slugify the workflow name for filename
  local filename
  filename="$(slugify "$workflow_name").json"
  local filepath="$WORKFLOWS_DIR/$filename"

  # Check if file exists and compare
  local needs_update=false

  if [ -f "$filepath" ]; then
    # Compare existing file with new data
    local existing_data
    existing_data=$(cat "$filepath")

    # Normalize both for comparison (remove id, updatedAt, createdAt)
    local normalized_existing
    local normalized_new

    normalized_existing=$(echo "$existing_data" | jq 'del(.id, .updatedAt, .createdAt, .versionId) | .')
    normalized_new=$(echo "$workflow_data" | jq 'del(.id, .updatedAt, .createdAt, .versionId) | .')

    if [ "$normalized_existing" != "$normalized_new" ]; then
      needs_update=true
    fi
  else
    needs_update=true
  fi

  if [ "$FORCE_MODE" = true ]; then
    needs_update=true
  fi

  if [ "$DIFF_MODE" = true ]; then
    if [ "$needs_update" = true ]; then
      if [ -f "$filepath" ]; then
        echo "MODIFIED: $filename"
      else
        echo "NEW:      $filename"
      fi
    fi
  else
    if [ "$needs_update" = true ]; then
      # Export the workflow (pretty-printed)
      echo "$workflow_data" | jq '.' > "$filepath"

      if [ -f "$filepath" ]; then
        log_success "Exported: $filename"
      else
        log_success "Created: $filename"
      fi
    else
      log_info "Unchanged: $filename"
    fi
  fi
}

# Fetch and export credential structure (no secrets)
export_credentials_structure() {
  log_info "Fetching credential structure..."

  # Get admin credentials for authentication
  local admin_email="${N8N_ADMIN_EMAIL:-github.n8n.$(basename "$REPO_ROOT")@lee-solutionsgroup.com}"
  local admin_password="${N8N_ADMIN_PASSWORD:-}"

  if [ -z "$admin_password" ]; then
    log_warn "N8N_ADMIN_PASSWORD not found, skipping credential structure export"
    return 0
  fi

  # Login to get session cookie
  local cookie_jar=$(mktemp)
  local login_response
  login_response=$(curl -sf -X POST "$N8N_URL/rest/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$admin_email\",\"password\":\"$admin_password\"}" \
    -c "$cookie_jar" 2>/dev/null || echo "")

  if ! echo "$login_response" | jq -e '.data' &>/dev/null; then
    log_warn "Failed to authenticate for credential export, skipping"
    rm -f "$cookie_jar"
    return 0
  fi

  # Fetch credentials (will not include secret values)
  local creds_response
  creds_response=$(curl -sf "$N8N_URL/rest/credentials" \
    -b "$cookie_jar" 2>/dev/null || echo "")

  rm -f "$cookie_jar"

  if ! echo "$creds_response" | jq -e '.data' &>/dev/null; then
    log_warn "Failed to fetch credentials, skipping credential structure export"
    return 0
  fi

  # Extract credential structure (type, name, no secret data)
  local creds_structure
  creds_structure=$(echo "$creds_response" | jq '[.data[] | {
    type: .type,
    name: .name,
    id: .id
  }]')

  local creds_file="$WORKFLOWS_DIR/credentials-structure.json"

  if [ "$DIFF_MODE" = true ]; then
    if [ -f "$creds_file" ]; then
      local existing_creds
      existing_creds=$(cat "$creds_file")

      if [ "$existing_creds" != "$creds_structure" ]; then
        echo "MODIFIED: credentials-structure.json"
      fi
    else
      echo "NEW:      credentials-structure.json"
    fi
  else
    echo "$creds_structure" | jq '.' > "$creds_file"
    log_success "Exported: credentials-structure.json"
  fi
}

# Export n8n settings
export_settings() {
  log_info "Exporting n8n settings..."

  # Extract pinned version from docker-compose file
  local compose_file="$REPO_ROOT/deploy/n8n/docker-compose.n8n.yml"
  local pinned_version=""

  if [ -f "$compose_file" ]; then
    pinned_version=$(grep -E "image:.*n8n" "$compose_file" | sed 's/.*://g' | tr -d ' ' || echo "unknown")
  fi

  # Get running version
  local running_version=""
  if command -v docker &>/dev/null; then
    # Auto-detect repository name for per-repo container naming
    local repo_name
    repo_name=$(basename "$(cd "$REPO_ROOT" && git rev-parse --show-toplevel 2>/dev/null)" || basename "$REPO_ROOT")
    local container_name="n8n-${repo_name}"

    running_version=$(docker exec "$container_name" n8n --version 2>/dev/null | head -1 || echo "unknown")
  fi

  # Create settings file
  local settings_file="$WORKFLOWS_DIR/.n8n-export-metadata.json"
  local settings_data
  settings_data=$(jq -n \
    --arg pinned "$pinned_version" \
    --arg running "$running_version" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg url "$N8N_URL" \
    '{
      export_timestamp: $timestamp,
      n8n_url: $url,
      version: {
        pinned: $pinned,
        running: $running
      },
      note: "This file tracks export metadata. Do not edit manually."
    }')

  if [ "$DIFF_MODE" = true ]; then
    if [ -f "$settings_file" ]; then
      echo "MODIFIED: .n8n-export-metadata.json"
    else
      echo "NEW:      .n8n-export-metadata.json"
    fi
  else
    echo "$settings_data" | jq '.' > "$settings_file"
    log_success "Exported: .n8n-export-metadata.json"
  fi
}

# Main export function
main() {
  if [ "$DIFF_MODE" = true ]; then
    log_info "Running in DIFF mode - showing changes without exporting"
  else
    log_info "n8n Workflow Export"
  fi
  echo ""

  check_prerequisites
  check_n8n_running

  # Create workflows directory if it doesn't exist
  if [ ! -d "$WORKFLOWS_DIR" ]; then
    if [ "$DIFF_MODE" = false ]; then
      mkdir -p "$WORKFLOWS_DIR"
      log_info "Created workflows directory: $WORKFLOWS_DIR"
    fi
  fi

  # Fetch all workflows
  local workflows_response
  workflows_response=$(fetch_workflows)

  local workflow_count
  workflow_count=$(echo "$workflows_response" | jq '.data | length')

  log_info "Found $workflow_count workflows"
  echo ""

  # Export each workflow
  local exported_count=0
  local unchanged_count=0
  local i=0

  while [ $i -lt "$workflow_count" ]; do
    local workflow
    workflow=$(echo "$workflows_response" | jq -c ".data[$i]")

    local workflow_id
    local workflow_name

    workflow_id=$(echo "$workflow" | jq -r '.id')
    workflow_name=$(echo "$workflow" | jq -r '.name')

    # Fetch full workflow data (the list endpoint may not include all fields)
    local full_workflow
    full_workflow=$(curl -sf "$N8N_URL/api/v1/workflows/$workflow_id" \
      -H "X-N8N-API-KEY: $N8N_API_KEY" 2>/dev/null || echo "")

    if echo "$full_workflow" | jq -e '.data' &>/dev/null; then
      local workflow_data
      workflow_data=$(echo "$full_workflow" | jq '.data')

      export_workflow "$workflow_id" "$workflow_name" "$workflow_data"
      exported_count=$((exported_count + 1))
    else
      log_warn "Failed to fetch full data for workflow: $workflow_name (ID: $workflow_id)"
    fi

    i=$((i + 1))
  done

  echo ""

  # Export credential structure
  export_credentials_structure

  # Export settings
  export_settings

  echo ""

  if [ "$DIFF_MODE" = true ]; then
    log_success "Diff complete - changes shown above"
  else
    log_success "Export complete!"
    echo ""
    echo "Summary:"
    echo "  Workflows exported: $exported_count"
    echo "  Export location:    $WORKFLOWS_DIR"
    echo ""
    echo "Next steps:"
    echo "  - Review exported files: ls -la $WORKFLOWS_DIR"
    echo "  - Commit to version control: git add n8n-workflows/ && git commit"
    echo "  - To import elsewhere: ./scripts/n8n-import-config.sh"
    echo ""
  fi
}

main
