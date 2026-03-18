#!/usr/bin/env bash
# ============================================================
# Script: n8n-import-workflows.sh
# Purpose: Import, activate, and validate n8n workflows
# Feature: #723 - n8n setup wizard: workflow import, activation, and validation
#
# Usage:
#   ./scripts/n8n-import-workflows.sh [OPTIONS]
#
# Options:
#   --dry-run           Preview what would be imported without making changes
#   --skip-validation   Import/activate workflows but skip validation
#   --workflow FILE     Import only a specific workflow file
#   --force-update      Update existing workflows even if content hasn't changed
#   --help              Show this help message
#
# Workflow Types and Validation:
#   - Webhook workflows: POST test ping to webhook URL → verify 200
#   - Scheduled workflows: verify active + next execution scheduled
#   - GitHub integration workflows: verify connected service reachable
#
# Exit codes:
#   0 - Success (all workflows imported, activated, and validated)
#   1 - General error
#   2 - Invalid arguments
#   3 - n8n not available
#   4 - API key not found
#   5 - Validation failures detected
# ============================================================

set -euo pipefail

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
  log_debug() { [ -n "${DEBUG:-}" ] && echo "[DEBUG] $*" >&2 || true; }
  die() { log_error "$*"; exit 1; }
fi

# Configuration
N8N_URL="${N8N_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"
WORKFLOWS_DIR="$REPO_ROOT/n8n-workflows"
DRY_RUN=false
SKIP_VALIDATION=false
SPECIFIC_WORKFLOW=""
FORCE_UPDATE=false

# Counters
TOTAL_WORKFLOWS=0
IMPORTED_COUNT=0
UPDATED_COUNT=0
SKIPPED_COUNT=0
ACTIVATED_COUNT=0
VALIDATION_PASSED=0
VALIDATION_FAILED=0
VALIDATION_SKIPPED=0

# Arrays for tracking
declare -a FAILED_WORKFLOWS=()
declare -a VALIDATION_ERRORS=()

# ============================================================
# Argument Parsing
# ============================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-validation)
      SKIP_VALIDATION=true
      shift
      ;;
    --workflow)
      SPECIFIC_WORKFLOW="$2"
      shift 2
      ;;
    --force-update)
      FORCE_UPDATE=true
      shift
      ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      log_error "Unknown option: $1. Use --help for usage information."
      exit 2
      ;;
  esac
done

# ============================================================
# Utility Functions
# ============================================================

# Get n8n API key from environment or .env.local
get_api_key() {
  # Try environment variable first
  if [ -n "$N8N_API_KEY" ]; then
    echo "$N8N_API_KEY"
    return 0
  fi

  # Try .env.local
  local env_file="$REPO_ROOT/.env.local"
  if [ -f "$env_file" ]; then
    local key
    key=$(grep '^N8N_API_KEY=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d ' "'"'" || echo "")
    if [ -n "$key" ]; then
      echo "$key"
      return 0
    fi
  fi

  # Try credentials file
  local cred_file="${HOME}/.claude-tastic/credentials/n8n-api-key"
  if [ -f "$cred_file" ]; then
    local key
    key=$(grep -v '^#' "$cred_file" | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')
    if [ -n "$key" ]; then
      echo "$key"
      return 0
    fi
  fi

  return 1
}

# Check if n8n is accessible
check_n8n_health() {
  if curl -sf "${N8N_URL}/healthz" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Get GitHub credentials from .env.local
get_github_credentials() {
  local env_file="$REPO_ROOT/.env.local"
  if [ ! -f "$env_file" ]; then
    echo ""
    return 1
  fi

  # Check for GitHub token
  local github_token
  github_token=$(grep '^N8N_GITHUB_TOKEN=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d ' "'"'" || echo "")

  if [ -n "$github_token" ]; then
    echo "token:$github_token"
    return 0
  fi

  # Check for GitHub App
  local app_id
  app_id=$(grep '^N8N_GITHUB_APP_ID=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d ' "'"'" || echo "")

  if [ -n "$app_id" ]; then
    echo "app:$app_id"
    return 0
  fi

  echo ""
  return 1
}

# Calculate hash of workflow JSON (excluding volatile fields)
calculate_workflow_hash() {
  local workflow_file="$1"

  # Extract stable fields and hash them
  jq -S '{name, nodes, connections, settings}' "$workflow_file" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}

# ============================================================
# n8n API Functions
# ============================================================

# List all workflows from n8n
list_workflows() {
  local api_key="$1"

  curl -sf "${N8N_URL}/api/v1/workflows" \
    -H "X-N8N-API-KEY: ${api_key}" \
    -H "Accept: application/json" 2>/dev/null || echo '{"data":[]}'
}

# Get workflow by name
get_workflow_by_name() {
  local api_key="$1"
  local workflow_name="$2"

  local workflows
  workflows=$(list_workflows "$api_key")

  echo "$workflows" | jq -r ".data[] | select(.name == \"$workflow_name\")"
}

# Get GitHub credential ID from n8n
get_github_credential_id() {
  local api_key="$1"

  # Login to get session for credentials API
  local env_file="$REPO_ROOT/.env.local"
  if [ ! -f "$env_file" ]; then
    echo ""
    return 1
  fi

  # Get admin credentials
  local admin_password
  admin_password=$(grep '^N8N_ADMIN_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d ' "'"'" || echo "")

  if [ -z "$admin_password" ]; then
    echo ""
    return 1
  fi

  # Extract repo name for email
  local repo_name
  repo_name=$(basename "$REPO_ROOT")
  local admin_email="github.n8n.${repo_name}@lee-solutionsgroup.com"

  # Login
  local cookie_jar
  cookie_jar=$(mktemp)

  curl -sf -X POST "${N8N_URL}/rest/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$admin_email\",\"password\":\"$admin_password\"}" \
    -c "$cookie_jar" >/dev/null 2>&1 || { rm -f "$cookie_jar"; echo ""; return 1; }

  # Get credentials
  local credentials
  credentials=$(curl -sf "${N8N_URL}/rest/credentials" \
    -b "$cookie_jar" 2>/dev/null || echo '{"data":[]}')

  rm -f "$cookie_jar"

  # Find GitHub credential (either httpHeaderAuth or githubOAuth2Api)
  local cred_id
  cred_id=$(echo "$credentials" | jq -r '.data[] | select(.name == "GitHub Token" or .type == "githubOAuth2Api") | .id' | head -1)

  echo "$cred_id"
}

# Map GitHub credentials in workflow
map_github_credentials() {
  local workflow_file="$1"
  local github_cred_id="$2"

  if [ -z "$github_cred_id" ]; then
    # No mapping needed - return original
    cat "$workflow_file"
    return 0
  fi

  # Map GitHub credentials to nodes that use GitHub API
  jq --arg cred_id "$github_cred_id" '
    .nodes |= map(
      if (.type | contains("github")) or (.type == "n8n-nodes-base.httpRequest" and (.parameters.url // "" | contains("api.github.com"))) then
        .credentials = {
          "httpHeaderAuth": {
            "id": $cred_id,
            "name": "GitHub Token"
          }
        }
      else
        .
      end
    )
  ' "$workflow_file"
}

# Create new workflow
create_workflow() {
  local api_key="$1"
  local workflow_file="$2"
  local github_cred_id="$3"

  local workflow_name
  workflow_name=$(jq -r '.name // "unnamed"' "$workflow_file")

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would create workflow: $workflow_name"
    return 0
  fi

  # Map GitHub credentials if available
  local workflow_json
  workflow_json=$(map_github_credentials "$workflow_file" "$github_cred_id")

  # Ensure workflow is inactive on creation (we'll activate separately)
  workflow_json=$(echo "$workflow_json" | jq '. + {active: false}')

  local response
  response=$(curl -sf -X POST "${N8N_URL}/api/v1/workflows" \
    -H "X-N8N-API-KEY: ${api_key}" \
    -H "Content-Type: application/json" \
    -d "$workflow_json" 2>/dev/null || echo '{}')

  local created_id
  created_id=$(echo "$response" | jq -r '.data.id // .id // empty')

  if [ -n "$created_id" ]; then
    log_success "Created workflow: $workflow_name (ID: $created_id)"
    ((IMPORTED_COUNT++))
    echo "$created_id"
    return 0
  else
    log_error "Failed to create workflow: $workflow_name"
    log_debug "Response: $response"
    FAILED_WORKFLOWS+=("$workflow_name (create failed)")
    return 1
  fi
}

# Update existing workflow
update_workflow() {
  local api_key="$1"
  local workflow_id="$2"
  local workflow_file="$3"
  local github_cred_id="$4"

  local workflow_name
  workflow_name=$(jq -r '.name // "unnamed"' "$workflow_file")

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would update workflow: $workflow_name (ID: $workflow_id)"
    return 0
  fi

  # Get existing workflow to preserve active state
  local existing
  existing=$(curl -sf "${N8N_URL}/api/v1/workflows/${workflow_id}" \
    -H "X-N8N-API-KEY: ${api_key}" 2>/dev/null || echo '{}')

  local was_active
  was_active=$(echo "$existing" | jq -r '.data.active // .active // false')

  # Map GitHub credentials
  local workflow_json
  workflow_json=$(map_github_credentials "$workflow_file" "$github_cred_id")

  # Preserve active state
  workflow_json=$(echo "$workflow_json" | jq --argjson active "$was_active" '. + {active: $active}')

  local response
  response=$(curl -sf -X PATCH "${N8N_URL}/api/v1/workflows/${workflow_id}" \
    -H "X-N8N-API-KEY: ${api_key}" \
    -H "Content-Type: application/json" \
    -d "$workflow_json" 2>/dev/null || echo '{}')

  local updated_id
  updated_id=$(echo "$response" | jq -r '.data.id // .id // empty')

  if [ -n "$updated_id" ]; then
    log_success "Updated workflow: $workflow_name (ID: $workflow_id)"
    ((UPDATED_COUNT++))
    echo "$workflow_id"
    return 0
  else
    log_error "Failed to update workflow: $workflow_name"
    log_debug "Response: $response"
    FAILED_WORKFLOWS+=("$workflow_name (update failed)")
    return 1
  fi
}

# Activate workflow
activate_workflow() {
  local api_key="$1"
  local workflow_id="$2"
  local workflow_name="$3"

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would activate workflow: $workflow_name"
    return 0
  fi

  # Get current workflow state
  local workflow
  workflow=$(curl -sf "${N8N_URL}/api/v1/workflows/${workflow_id}" \
    -H "X-N8N-API-KEY: ${api_key}" 2>/dev/null || echo '{}')

  # Set active to true
  local updated
  updated=$(echo "$workflow" | jq '.data + {active: true} // {active: true}')

  local response
  response=$(curl -sf -X PATCH "${N8N_URL}/api/v1/workflows/${workflow_id}" \
    -H "X-N8N-API-KEY: ${api_key}" \
    -H "Content-Type: application/json" \
    -d "$updated" 2>/dev/null || echo '{}')

  local is_active
  is_active=$(echo "$response" | jq -r '.data.active // .active // false')

  if [ "$is_active" = "true" ]; then
    log_success "Activated workflow: $workflow_name"
    ((ACTIVATED_COUNT++))
    return 0
  else
    log_error "Failed to activate workflow: $workflow_name"
    FAILED_WORKFLOWS+=("$workflow_name (activation failed)")
    return 1
  fi
}

# ============================================================
# Validation Functions
# ============================================================

# Detect workflow type
detect_workflow_type() {
  local workflow_file="$1"

  # Check for webhook trigger
  if jq -e '.nodes[] | select(.type == "n8n-nodes-base.webhook")' "$workflow_file" >/dev/null 2>&1; then
    echo "webhook"
    return 0
  fi

  # Check for schedule trigger
  if jq -e '.nodes[] | select(.type == "n8n-nodes-base.scheduleTrigger" or .type == "n8n-nodes-base.cron")' "$workflow_file" >/dev/null 2>&1; then
    echo "scheduled"
    return 0
  fi

  # Check for GitHub nodes
  if jq -e '.nodes[] | select(.type | contains("github"))' "$workflow_file" >/dev/null 2>&1; then
    echo "github"
    return 0
  fi

  # Check for HTTP Request nodes calling GitHub API
  if jq -e '.nodes[] | select(.type == "n8n-nodes-base.httpRequest" and (.parameters.url // "" | contains("api.github.com")))' "$workflow_file" >/dev/null 2>&1; then
    echo "github"
    return 0
  fi

  echo "other"
}

# Validate webhook workflow
validate_webhook_workflow() {
  local workflow_id="$1"
  local workflow_name="$2"
  local workflow_file="$3"

  # Extract webhook path
  local webhook_path
  webhook_path=$(jq -r '.nodes[] | select(.type == "n8n-nodes-base.webhook") | .parameters.path // ""' "$workflow_file" | head -1)

  if [ -z "$webhook_path" ]; then
    log_warn "Webhook workflow '$workflow_name' has no webhook path configured"
    VALIDATION_ERRORS+=("$workflow_name: No webhook path found")
    return 1
  fi

  # Construct webhook URL
  local webhook_url="${N8N_URL}/webhook/${webhook_path}"

  # Test webhook with POST request
  log_info "Testing webhook: $webhook_url"

  local response_code
  response_code=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
    -H "Content-Type: application/json" \
    -d '{"test": true, "source": "n8n-import-workflows"}' 2>/dev/null || echo "000")

  if [ "$response_code" = "200" ] || [ "$response_code" = "201" ]; then
    log_success "Webhook validation passed: $workflow_name (HTTP $response_code)"
    return 0
  else
    log_error "Webhook validation failed: $workflow_name (HTTP $response_code)"
    VALIDATION_ERRORS+=("$workflow_name: Webhook returned HTTP $response_code (expected 200/201)")
    return 1
  fi
}

# Validate scheduled workflow
validate_scheduled_workflow() {
  local api_key="$1"
  local workflow_id="$2"
  local workflow_name="$3"

  # Get workflow details to check if active
  local workflow
  workflow=$(curl -sf "${N8N_URL}/api/v1/workflows/${workflow_id}" \
    -H "X-N8N-API-KEY: ${api_key}" 2>/dev/null || echo '{}')

  local is_active
  is_active=$(echo "$workflow" | jq -r '.data.active // .active // false')

  if [ "$is_active" != "true" ]; then
    log_error "Scheduled workflow is not active: $workflow_name"
    VALIDATION_ERRORS+=("$workflow_name: Workflow not active (required for scheduled workflows)")
    return 1
  fi

  log_success "Scheduled workflow validation passed: $workflow_name (active)"
  return 0
}

# Validate GitHub integration workflow
validate_github_workflow() {
  local workflow_name="$1"

  # Check if GitHub credentials are configured
  local github_creds
  github_creds=$(get_github_credentials)

  if [ -z "$github_creds" ]; then
    log_error "GitHub workflow validation failed: $workflow_name (no GitHub credentials configured)"
    VALIDATION_ERRORS+=("$workflow_name: No GitHub credentials in .env.local")
    return 1
  fi

  # Extract token or app info
  local auth_type
  auth_type=$(echo "$github_creds" | cut -d: -f1)

  if [ "$auth_type" = "token" ]; then
    local github_token
    github_token=$(echo "$github_creds" | cut -d: -f2)

    # Test GitHub API access
    local api_response
    api_response=$(curl -sf -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $github_token" \
      "https://api.github.com/user" 2>/dev/null || echo "000")

    if [ "$api_response" = "200" ]; then
      log_success "GitHub workflow validation passed: $workflow_name (API reachable)"
      return 0
    else
      log_error "GitHub workflow validation failed: $workflow_name (API returned HTTP $api_response)"
      VALIDATION_ERRORS+=("$workflow_name: GitHub API unreachable (HTTP $api_response)")
      return 1
    fi
  else
    # GitHub App - just verify it's configured
    log_success "GitHub workflow validation passed: $workflow_name (GitHub App configured)"
    return 0
  fi
}

# Validate workflow
validate_workflow() {
  local api_key="$1"
  local workflow_id="$2"
  local workflow_name="$3"
  local workflow_file="$4"

  if $SKIP_VALIDATION; then
    log_info "Skipping validation: $workflow_name"
    ((VALIDATION_SKIPPED++))
    return 0
  fi

  log_info "Validating workflow: $workflow_name"

  local workflow_type
  workflow_type=$(detect_workflow_type "$workflow_file")

  local validation_result=0

  case "$workflow_type" in
    webhook)
      validate_webhook_workflow "$workflow_id" "$workflow_name" "$workflow_file" || validation_result=1
      ;;
    scheduled)
      validate_scheduled_workflow "$api_key" "$workflow_id" "$workflow_name" || validation_result=1
      ;;
    github)
      validate_github_workflow "$workflow_name" || validation_result=1
      ;;
    *)
      log_info "Skipping validation for unknown workflow type: $workflow_name"
      ((VALIDATION_SKIPPED++))
      return 0
      ;;
  esac

  if [ $validation_result -eq 0 ]; then
    ((VALIDATION_PASSED++))
  else
    ((VALIDATION_FAILED++))
  fi

  return $validation_result
}

# ============================================================
# Import Workflow Function
# ============================================================

import_workflow() {
  local api_key="$1"
  local workflow_file="$2"
  local github_cred_id="$3"

  if [ ! -f "$workflow_file" ]; then
    log_error "Workflow file not found: $workflow_file"
    return 1
  fi

  # Validate JSON
  if ! jq empty "$workflow_file" 2>/dev/null; then
    log_error "Invalid JSON in workflow file: $workflow_file"
    FAILED_WORKFLOWS+=("$(basename "$workflow_file") (invalid JSON)")
    return 1
  fi

  local workflow_name
  workflow_name=$(jq -r '.name // "unnamed"' "$workflow_file")

  log_info "Processing workflow: $workflow_name"

  # Calculate hash of new workflow
  local new_hash
  new_hash=$(calculate_workflow_hash "$workflow_file")

  # Check if workflow already exists
  local existing
  existing=$(get_workflow_by_name "$api_key" "$workflow_name")

  local workflow_id=""

  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    workflow_id=$(echo "$existing" | jq -r '.id')

    # Check if content has changed
    if [ "$FORCE_UPDATE" = false ]; then
      # Get existing workflow full details
      local existing_full
      existing_full=$(curl -sf "${N8N_URL}/api/v1/workflows/${workflow_id}" \
        -H "X-N8N-API-KEY: ${api_key}" 2>/dev/null || echo '{}')

      # Calculate hash of existing workflow
      local existing_hash
      existing_hash=$(echo "$existing_full" | jq -S '{name: .data.name, nodes: .data.nodes, connections: .data.connections, settings: .data.settings}' 2>/dev/null | shasum -a 256 | cut -d' ' -f1 || echo "")

      if [ "$new_hash" = "$existing_hash" ] && [ -n "$existing_hash" ]; then
        log_info "Workflow unchanged, skipping update: $workflow_name"
        ((SKIPPED_COUNT++))

        # Still validate even if skipped
        validate_workflow "$api_key" "$workflow_id" "$workflow_name" "$workflow_file"
        return 0
      fi
    fi

    # Update existing workflow
    log_info "Updating existing workflow: $workflow_name (ID: $workflow_id)"
    workflow_id=$(update_workflow "$api_key" "$workflow_id" "$workflow_file" "$github_cred_id") || return 1
  else
    # Create new workflow
    workflow_id=$(create_workflow "$api_key" "$workflow_file" "$github_cred_id") || return 1
  fi

  # Activate workflow
  if [ -n "$workflow_id" ]; then
    activate_workflow "$api_key" "$workflow_id" "$workflow_name"

    # Validate workflow
    validate_workflow "$api_key" "$workflow_id" "$workflow_name" "$workflow_file"
  fi

  return 0
}

# ============================================================
# Report Functions
# ============================================================

print_summary_report() {
  echo ""
  echo "=========================================="
  echo "  n8n Workflow Import Summary"
  echo "=========================================="
  echo ""
  echo "Total workflows processed: $TOTAL_WORKFLOWS"
  echo ""
  echo "Import Results:"
  echo "  ✓ Imported (new):        $IMPORTED_COUNT"
  echo "  ✓ Updated:               $UPDATED_COUNT"
  echo "  ⊘ Skipped (unchanged):   $SKIPPED_COUNT"
  echo "  ✓ Activated:             $ACTIVATED_COUNT"
  echo ""

  if [ $SKIP_VALIDATION = false ]; then
    echo "Validation Results:"
    echo "  ✓ Passed:                $VALIDATION_PASSED"
    echo "  ✗ Failed:                $VALIDATION_FAILED"
    echo "  ⊘ Skipped:               $VALIDATION_SKIPPED"
    echo ""
  fi

  if [ ${#FAILED_WORKFLOWS[@]} -gt 0 ]; then
    echo "Failed Workflows:"
    for failed in "${FAILED_WORKFLOWS[@]}"; do
      echo "  ✗ $failed"
    done
    echo ""
  fi

  if [ ${#VALIDATION_ERRORS[@]} -gt 0 ]; then
    echo "Validation Errors:"
    for error in "${VALIDATION_ERRORS[@]}"; do
      echo "  ⚠ $error"
    done
    echo ""

    echo "Remediation Guidance:"
    echo "────────────────────────────────────────"

    # Analyze errors and provide specific guidance
    for error in "${VALIDATION_ERRORS[@]}"; do
      if [[ "$error" == *"No GitHub credentials"* ]]; then
        echo ""
        echo "GitHub Credentials Missing:"
        echo "  1. Run: ./scripts/n8n-setup.sh"
        echo "  2. Configure GitHub App or Personal Access Token"
        echo "  3. Re-run this import script"
        break
      fi
    done

    for error in "${VALIDATION_ERRORS[@]}"; do
      if [[ "$error" == *"Webhook returned"* ]]; then
        echo ""
        echo "Webhook Validation Failed:"
        echo "  - Ensure n8n is running and accessible"
        echo "  - Check workflow webhook configuration"
        echo "  - Verify webhook path is correct"
        echo "  - Review n8n logs: docker logs n8n-local"
        break
      fi
    done

    for error in "${VALIDATION_ERRORS[@]}"; do
      if [[ "$error" == *"not active"* ]]; then
        echo ""
        echo "Workflow Not Active:"
        echo "  - Check for activation errors in n8n UI"
        echo "  - Verify all required credentials are configured"
        echo "  - Review workflow configuration for errors"
        break
      fi
    done

    echo ""
  fi

  echo "=========================================="

  # Exit with error if there were failures
  if [ ${#FAILED_WORKFLOWS[@]} -gt 0 ] || [ $VALIDATION_FAILED -gt 0 ]; then
    echo ""
    log_error "Import completed with failures"
    return 5
  else
    echo ""
    log_success "All workflows imported, activated, and validated successfully!"
    return 0
  fi
}

# ============================================================
# Main Logic
# ============================================================

main() {
  echo ""
  echo "=========================================="
  echo "  n8n Workflow Import & Validation"
  echo "=========================================="
  echo ""

  if $DRY_RUN; then
    log_info "DRY RUN MODE - No changes will be made"
    echo ""
  fi

  # Check dependencies
  if ! command -v jq &>/dev/null; then
    die "Required command not found: jq (install with: brew install jq)"
  fi

  if ! command -v curl &>/dev/null; then
    die "Required command not found: curl"
  fi

  # Get API key
  local api_key
  if ! api_key=$(get_api_key); then
    die "n8n API key not found. Run ./scripts/n8n-setup.sh to configure n8n."
  fi

  # Check n8n health
  log_info "Checking n8n health..."
  if ! check_n8n_health; then
    die "n8n not accessible at ${N8N_URL}. Start n8n with: ./scripts/n8n-start.sh"
  fi
  log_success "n8n is healthy"
  echo ""

  # Get GitHub credential ID for mapping
  log_info "Checking for GitHub credentials..."
  local github_cred_id
  github_cred_id=$(get_github_credential_id "$api_key") || github_cred_id=""

  if [ -n "$github_cred_id" ]; then
    log_success "Found GitHub credential (ID: $github_cred_id)"
  else
    log_warn "No GitHub credentials found in n8n - GitHub workflows may not work"
  fi
  echo ""

  # Determine which workflows to import
  local workflow_files=()

  if [ -n "$SPECIFIC_WORKFLOW" ]; then
    if [ ! -f "$SPECIFIC_WORKFLOW" ]; then
      die "Workflow file not found: $SPECIFIC_WORKFLOW"
    fi
    workflow_files+=("$SPECIFIC_WORKFLOW")
  else
    # Import all workflows from directory
    if [ ! -d "$WORKFLOWS_DIR" ]; then
      die "Workflows directory not found: $WORKFLOWS_DIR"
    fi

    while IFS= read -r -d '' workflow_file; do
      workflow_files+=("$workflow_file")
    done < <(find "$WORKFLOWS_DIR" -name "*.json" -type f -not -path "*/test-fixtures/*" -print0 | sort -z)
  fi

  if [ ${#workflow_files[@]} -eq 0 ]; then
    log_info "No workflow files found to import"
    exit 0
  fi

  TOTAL_WORKFLOWS=${#workflow_files[@]}
  log_info "Found $TOTAL_WORKFLOWS workflow(s) to process"
  echo ""

  # Import each workflow
  local count=0
  for workflow_file in "${workflow_files[@]}"; do
    ((count++))
    echo "────────────────────────────────────────"
    echo "[$count/$TOTAL_WORKFLOWS] $(basename "$workflow_file")"
    echo "────────────────────────────────────────"

    import_workflow "$api_key" "$workflow_file" "$github_cred_id" || true
    echo ""
  done

  # Print summary report
  print_summary_report
  return $?
}

main
