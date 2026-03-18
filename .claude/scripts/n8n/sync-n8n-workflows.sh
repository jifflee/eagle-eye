#!/usr/bin/env bash
#
# sync-n8n-workflows.sh
# Sync n8n workflows via n8n API
# Feature #517: n8n workflow sync integration
# size-ok: n8n API integration for workflow sync with upsert logic
#
# Usage:
#   ./sync-n8n-workflows.sh                # Sync all workflows from n8n-workflows/
#   ./sync-n8n-workflows.sh WORKFLOW_FILE  # Sync specific workflow
#   ./sync-n8n-workflows.sh --dry-run      # Preview what would be synced
#   ./sync-n8n-workflows.sh --list         # List workflows in n8n
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Invalid arguments
#   3 - n8n not available
#   4 - API key not found
#

set -euo pipefail

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    source "${SCRIPT_DIR}/lib/common.sh"
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
N8N_API_KEY_FILE="${HOME}/.claude-tastic/credentials/n8n-api-key"
WORKFLOWS_DIR="${REPO_DIR}/n8n-workflows"
DRY_RUN=false
LIST_MODE=false
SPECIFIC_WORKFLOW=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --list)
            LIST_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [WORKFLOW_FILE]"
            echo ""
            echo "Sync n8n workflows via n8n API."
            echo ""
            echo "Options:"
            echo "  --dry-run       Show what would be synced without making changes"
            echo "  --list          List workflows currently in n8n"
            echo "  --help          Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                              # Sync all workflows"
            echo "  $0 workflow.json                # Sync specific workflow"
            echo "  $0 --dry-run                    # Preview changes"
            echo "  $0 --list                       # List n8n workflows"
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 2
            ;;
        *)
            SPECIFIC_WORKFLOW="$1"
            shift
            ;;
    esac
done

# ============================================================
# n8n API Functions
# ============================================================

# Get n8n API key
get_api_key() {
    # Try environment variable first
    if [ -n "${N8N_API_KEY:-}" ]; then
        echo "$N8N_API_KEY"
        return 0
    fi

    # Try credentials file
    if [ -f "$N8N_API_KEY_FILE" ]; then
        # Read first non-comment, non-empty line
        local key
        key=$(grep -v '^#' "$N8N_API_KEY_FILE" | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')
        if [ -n "$key" ]; then
            echo "$key"
            return 0
        fi
    fi

    return 1
}

# Check if n8n is accessible
check_n8n() {
    if ! curl -sf "${N8N_URL}/healthz" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# List all workflows from n8n
list_n8n_workflows() {
    local api_key="$1"

    curl -s "${N8N_URL}/api/v1/workflows" \
        -H "X-N8N-API-KEY: ${api_key}" \
        -H "Accept: application/json"
}

# Get workflow by name
get_workflow_by_name() {
    local api_key="$1"
    local workflow_name="$2"

    local workflows
    workflows=$(list_n8n_workflows "$api_key")

    echo "$workflows" | jq -r ".data[] | select(.name == \"$workflow_name\") | .id" | head -1
}

# Create new workflow
create_workflow() {
    local api_key="$1"
    local workflow_file="$2"

    if [ ! -f "$workflow_file" ]; then
        log_error "Workflow file not found: $workflow_file"
        return 1
    fi

    # Validate JSON
    if ! jq empty "$workflow_file" 2>/dev/null; then
        log_error "Invalid JSON in workflow file: $workflow_file"
        return 1
    fi

    local workflow_name
    workflow_name=$(jq -r '.name // .id // "unnamed"' "$workflow_file")

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would create workflow: $workflow_name"
        return 0
    fi

    local response
    response=$(curl -s -X POST "${N8N_URL}/api/v1/workflows" \
        -H "X-N8N-API-KEY: ${api_key}" \
        -H "Content-Type: application/json" \
        -d @"$workflow_file")

    local created_id
    created_id=$(echo "$response" | jq -r '.id // empty')

    if [ -n "$created_id" ]; then
        log_success "Created workflow: $workflow_name (ID: $created_id)"
        return 0
    else
        log_error "Failed to create workflow: $workflow_name"
        log_debug "Response: $response"
        return 1
    fi
}

# Update existing workflow
update_workflow() {
    local api_key="$1"
    local workflow_id="$2"
    local workflow_file="$3"

    if [ ! -f "$workflow_file" ]; then
        log_error "Workflow file not found: $workflow_file"
        return 1
    fi

    # Validate JSON
    if ! jq empty "$workflow_file" 2>/dev/null; then
        log_error "Invalid JSON in workflow file: $workflow_file"
        return 1
    fi

    local workflow_name
    workflow_name=$(jq -r '.name // .id // "unnamed"' "$workflow_file")

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would update workflow: $workflow_name (ID: $workflow_id)"
        return 0
    fi

    # Get existing workflow to preserve certain fields
    local existing
    existing=$(curl -s "${N8N_URL}/api/v1/workflows/${workflow_id}" \
        -H "X-N8N-API-KEY: ${api_key}")

    # Extract fields to preserve (credentials, active state)
    local active
    active=$(echo "$existing" | jq -r '.active // false')

    # Merge new workflow with preserved fields
    local merged
    merged=$(jq --argjson active "$active" \
        '. + {active: $active}' \
        "$workflow_file")

    local response
    response=$(curl -s -X PUT "${N8N_URL}/api/v1/workflows/${workflow_id}" \
        -H "X-N8N-API-KEY: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "$merged")

    local updated_id
    updated_id=$(echo "$response" | jq -r '.id // empty')

    if [ -n "$updated_id" ]; then
        log_success "Updated workflow: $workflow_name (ID: $workflow_id)"
        return 0
    else
        log_error "Failed to update workflow: $workflow_name"
        log_debug "Response: $response"
        return 1
    fi
}

# Upsert workflow (create or update)
upsert_workflow() {
    local api_key="$1"
    local workflow_file="$2"

    local workflow_name
    workflow_name=$(jq -r '.name // .id // "unnamed"' "$workflow_file")

    # Check if workflow already exists
    local existing_id
    existing_id=$(get_workflow_by_name "$api_key" "$workflow_name")

    if [ -n "$existing_id" ]; then
        # Update existing
        log_info "Found existing workflow: $workflow_name (ID: $existing_id)"
        update_workflow "$api_key" "$existing_id" "$workflow_file"
    else
        # Create new
        log_info "Creating new workflow: $workflow_name"
        create_workflow "$api_key" "$workflow_file"
    fi
}

# ============================================================
# Main Logic
# ============================================================

main() {
    # Check dependencies
    if ! command -v jq &>/dev/null; then
        die "Required command not found: jq"
    fi

    if ! command -v curl &>/dev/null; then
        die "Required command not found: curl"
    fi

    # Get API key
    local api_key
    if ! api_key=$(get_api_key); then
        die "n8n API key not found. Set N8N_API_KEY or add to ${N8N_API_KEY_FILE}"
    fi

    # Check n8n availability
    if ! check_n8n; then
        log_warn "n8n not accessible at ${N8N_URL}"
        log_info "Start n8n with: ./scripts/n8n-start.sh"
        exit 3
    fi

    # List mode
    if $LIST_MODE; then
        log_info "Workflows in n8n:"
        local workflows
        workflows=$(list_n8n_workflows "$api_key")
        echo "$workflows" | jq -r '.data[] | "  - \(.name) (ID: \(.id), Active: \(.active))"'
        exit 0
    fi

    # Sync workflows
    if [ -n "$SPECIFIC_WORKFLOW" ]; then
        # Sync specific workflow
        if [ ! -f "$SPECIFIC_WORKFLOW" ]; then
            die "Workflow file not found: $SPECIFIC_WORKFLOW"
        fi

        log_info "Syncing workflow: $SPECIFIC_WORKFLOW"
        upsert_workflow "$api_key" "$SPECIFIC_WORKFLOW"
    else
        # Sync all workflows from n8n-workflows directory
        if [ ! -d "$WORKFLOWS_DIR" ]; then
            log_warn "n8n workflows directory not found: $WORKFLOWS_DIR"
            exit 0
        fi

        local workflow_files
        workflow_files=$(find "$WORKFLOWS_DIR" -name "*.json" -type f)

        if [ -z "$workflow_files" ]; then
            log_info "No workflow files found in $WORKFLOWS_DIR"
            exit 0
        fi

        log_info "Syncing workflows from: $WORKFLOWS_DIR"

        local count=0
        local success=0
        local failed=0

        while IFS= read -r workflow_file; do
            ((count++))
            echo ""
            log_info "[$count] Processing: $(basename "$workflow_file")"

            if upsert_workflow "$api_key" "$workflow_file"; then
                ((success++))
            else
                ((failed++))
            fi
        done <<< "$workflow_files"

        echo ""
        log_info "Summary: $count total, $success succeeded, $failed failed"

        if [ $failed -gt 0 ]; then
            exit 1
        fi
    fi

    log_success "n8n workflow sync complete"
}

main
