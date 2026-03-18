#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: n8n-import-config.sh
# Purpose: Import n8n workflows from n8n-workflows/ to n8n instance
# Usage: ./scripts/n8n-import-config.sh [--update-existing] [--skip-credentials]
#
# Options:
#   --update-existing    Update existing workflows instead of creating new ones
#   --skip-credentials   Skip credential mapping prompt
#   --help               Show this help message
#
# Features:
#   - Imports workflows from n8n-workflows/ directory
#   - Maps credentials to current environment's configured credentials
#   - Validates workflows before import
#   - Updates existing workflows or creates new ones
#   - Standalone operation (outside setup wizard)
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
UPDATE_EXISTING=false
SKIP_CREDENTIALS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update-existing)
      UPDATE_EXISTING=true
      shift
      ;;
    --skip-credentials)
      SKIP_CREDENTIALS=true
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

  # Check for workflows directory
  if [ ! -d "$WORKFLOWS_DIR" ]; then
    die "Workflows directory not found: $WORKFLOWS_DIR. Please export workflows first with: ./scripts/n8n-export-config.sh"
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

# Fetch existing workflows from n8n
fetch_existing_workflows() {
  local response
  response=$(curl -sf "$N8N_URL/api/v1/workflows" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" 2>/dev/null || echo "")

  if [ -z "$response" ]; then
    echo "[]"
    return
  fi

  if echo "$response" | jq -e '.data' &>/dev/null; then
    echo "$response" | jq '.data'
  else
    echo "[]"
  fi
}

# Find existing workflow by name
find_workflow_by_name() {
  local workflow_name="$1"
  local existing_workflows="$2"

  echo "$existing_workflows" | jq -r --arg name "$workflow_name" '.[] | select(.name == $name) | .id' | head -1
}

# Get admin cookie for authenticated requests
get_admin_cookie() {
  local admin_email="${N8N_ADMIN_EMAIL:-github.n8n.$(basename "$REPO_ROOT")@lee-solutionsgroup.com}"
  local admin_password="${N8N_ADMIN_PASSWORD:-}"

  if [ -z "$admin_password" ]; then
    echo ""
    return
  fi

  local cookie_jar=$(mktemp)
  local login_response
  login_response=$(curl -sf -X POST "$N8N_URL/rest/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$admin_email\",\"password\":\"$admin_password\"}" \
    -c "$cookie_jar" 2>/dev/null || echo "")

  if echo "$login_response" | jq -e '.data' &>/dev/null; then
    echo "$cookie_jar"
  else
    rm -f "$cookie_jar"
    echo ""
  fi
}

# Fetch credentials from n8n
fetch_credentials() {
  local cookie_jar="$1"

  if [ -z "$cookie_jar" ]; then
    echo "[]"
    return
  fi

  local creds_response
  creds_response=$(curl -sf "$N8N_URL/rest/credentials" \
    -b "$cookie_jar" 2>/dev/null || echo "")

  if echo "$creds_response" | jq -e '.data' &>/dev/null; then
    echo "$creds_response" | jq '.data'
  else
    echo "[]"
  fi
}

# Map credential references to current environment
map_credentials() {
  local workflow_data="$1"
  local available_credentials="$2"

  if [ "$SKIP_CREDENTIALS" = true ]; then
    echo "$workflow_data"
    return
  fi

  # Extract credential references from workflow
  local workflow_creds
  workflow_creds=$(echo "$workflow_data" | jq -r '
    [.nodes[] | select(.credentials) | .credentials | to_entries[] | {type: .key, name: .value.name, id: .value.id}] | unique_by(.type, .name)
  ')

  local cred_count
  cred_count=$(echo "$workflow_creds" | jq 'length')

  if [ "$cred_count" -eq 0 ]; then
    echo "$workflow_data"
    return
  fi

  # Map each credential to available credentials in current environment
  local mapped_workflow="$workflow_data"
  local i=0

  while [ $i -lt "$cred_count" ]; do
    local cred_type
    local cred_name
    local old_id

    cred_type=$(echo "$workflow_creds" | jq -r ".[$i].type")
    cred_name=$(echo "$workflow_creds" | jq -r ".[$i].name")
    old_id=$(echo "$workflow_creds" | jq -r ".[$i].id")

    # Find matching credential in current environment
    local new_id
    new_id=$(echo "$available_credentials" | jq -r --arg type "$cred_type" --arg name "$cred_name" '
      .[] | select(.type == $type and .name == $name) | .id
    ' | head -1)

    if [ -n "$new_id" ] && [ "$new_id" != "null" ]; then
      # Update credential ID in workflow
      mapped_workflow=$(echo "$mapped_workflow" | jq --arg old_id "$old_id" --arg new_id "$new_id" '
        walk(if type == "object" and has("id") and .id == $old_id then .id = $new_id else . end)
      ')

      log_info "Mapped credential: $cred_name ($cred_type) → ID: $new_id"
    else
      log_warn "Credential not found in current environment: $cred_name ($cred_type)"
      log_warn "  The workflow may not work correctly until this credential is configured"
    fi

    i=$((i + 1))
  done

  echo "$mapped_workflow"
}

# Import a single workflow
import_workflow() {
  local workflow_file="$1"
  local existing_workflows="$2"
  local available_credentials="$3"

  local filename
  filename=$(basename "$workflow_file")

  # Skip metadata files
  if [[ "$filename" == .* ]] || [[ "$filename" == "credentials-structure.json" ]] || [[ "$filename" == "*.md" ]]; then
    return 0
  fi

  log_info "Processing: $filename"

  # Read workflow data
  local workflow_data
  workflow_data=$(cat "$workflow_file")

  # Validate JSON
  if ! echo "$workflow_data" | jq -e '.' &>/dev/null; then
    log_error "Invalid JSON in $filename, skipping"
    return 1
  fi

  # Extract workflow name
  local workflow_name
  workflow_name=$(echo "$workflow_data" | jq -r '.name')

  if [ -z "$workflow_name" ] || [ "$workflow_name" = "null" ]; then
    log_error "Workflow name not found in $filename, skipping"
    return 1
  fi

  # Map credentials to current environment
  workflow_data=$(map_credentials "$workflow_data" "$available_credentials")

  # Remove fields that shouldn't be imported
  workflow_data=$(echo "$workflow_data" | jq 'del(.id, .createdAt, .updatedAt, .versionId)')

  # Check if workflow already exists
  local existing_id
  existing_id=$(find_workflow_by_name "$workflow_name" "$existing_workflows")

  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    if [ "$UPDATE_EXISTING" = true ]; then
      # Update existing workflow
      log_info "Updating existing workflow: $workflow_name (ID: $existing_id)"

      local update_response
      update_response=$(curl -sf -X PUT "$N8N_URL/api/v1/workflows/$existing_id" \
        -H "X-N8N-API-KEY: $N8N_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$workflow_data" 2>/dev/null || echo "")

      if echo "$update_response" | jq -e '.data' &>/dev/null; then
        log_success "Updated: $workflow_name"
        return 0
      else
        log_error "Failed to update workflow: $workflow_name"
        echo "$update_response" | jq . 2>/dev/null || echo "$update_response"
        return 1
      fi
    else
      log_warn "Workflow already exists: $workflow_name (use --update-existing to update)"
      return 0
    fi
  else
    # Create new workflow
    log_info "Creating new workflow: $workflow_name"

    local create_response
    create_response=$(curl -sf -X POST "$N8N_URL/api/v1/workflows" \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$workflow_data" 2>/dev/null || echo "")

    if echo "$create_response" | jq -e '.data' &>/dev/null; then
      log_success "Created: $workflow_name"
      return 0
    else
      log_error "Failed to create workflow: $workflow_name"
      echo "$create_response" | jq . 2>/dev/null || echo "$create_response"
      return 1
    fi
  fi
}

# Main import function
main() {
  log_info "n8n Workflow Import"
  echo ""

  check_prerequisites
  check_n8n_running

  # Get admin cookie for credential access
  log_info "Authenticating for credential access..."
  local cookie_jar
  cookie_jar=$(get_admin_cookie)

  if [ -z "$cookie_jar" ]; then
    log_warn "Could not authenticate, credential mapping will be skipped"
  else
    log_success "Authenticated successfully"
  fi

  # Fetch existing workflows
  log_info "Fetching existing workflows..."
  local existing_workflows
  existing_workflows=$(fetch_existing_workflows)

  local existing_count
  existing_count=$(echo "$existing_workflows" | jq 'length')
  log_info "Found $existing_count existing workflows"

  # Fetch available credentials
  local available_credentials="[]"
  if [ -n "$cookie_jar" ] && [ "$SKIP_CREDENTIALS" = false ]; then
    log_info "Fetching available credentials..."
    available_credentials=$(fetch_credentials "$cookie_jar")

    local cred_count
    cred_count=$(echo "$available_credentials" | jq 'length')
    log_info "Found $cred_count available credentials"
  fi

  # Clean up cookie jar
  if [ -n "$cookie_jar" ]; then
    rm -f "$cookie_jar"
  fi

  echo ""
  log_info "Importing workflows from: $WORKFLOWS_DIR"
  echo ""

  # Import each workflow
  local success_count=0
  local failed_count=0
  local skipped_count=0

  for workflow_file in "$WORKFLOWS_DIR"/*.json; do
    if [ -f "$workflow_file" ]; then
      if import_workflow "$workflow_file" "$existing_workflows" "$available_credentials"; then
        success_count=$((success_count + 1))
      else
        failed_count=$((failed_count + 1))
      fi
    fi
  done

  echo ""
  log_success "Import complete!"
  echo ""
  echo "Summary:"
  echo "  Workflows imported: $success_count"
  echo "  Workflows failed:   $failed_count"
  echo ""

  if [ "$failed_count" -gt 0 ]; then
    log_warn "Some workflows failed to import. Check the logs above for details."
    echo ""
  fi

  echo "Next steps:"
  echo "  - Review imported workflows in n8n UI: $N8N_URL"
  echo "  - Configure any missing credentials"
  echo "  - Activate workflows as needed"
  echo ""
}

main
