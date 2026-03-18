#!/bin/bash
set -euo pipefail
# container-complete-notifier.sh
# Notify n8n webhook when container completes (Issue #726)
#
# This script detects execution context (host vs container) and uses the correct
# n8n URL for webhook notifications:
#   - Host: http://localhost:5678 (localhost binding)
#   - Container: http://n8n-${REPO_NAME}:5678 (Docker DNS via shared network)
#
# Usage:
#   ./scripts/container-complete-notifier.sh --issue <N> --status <status> [OPTIONS]
#
# Options:
#   --issue <N>         Issue number (required)
#   --status <status>   Completion status: success|failure|timeout (required)
#   --repo <owner/repo> Repository name (default: from git remote)
#   --webhook <path>    Webhook path (default: /webhook/container-complete)
#   --dry-run           Print URL without sending request
#   --debug             Enable debug logging
#   --help              Show this help message
#
# Environment variables:
#   REPO_NAME           Repository short name (e.g., "claude-agents")
#   N8N_PORT            n8n port (default: 5678)
#   RUNNING_IN_CONTAINER Set to "true" if running in container
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments or webhook request failed
#   2 - n8n not reachable

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities if available
if [ -f "${SCRIPT_DIR}/../lib/common.sh" ]; then
  source "${SCRIPT_DIR}/../lib/common.sh"
else
  # Minimal fallback if common.sh not available
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_debug() { [ "${DEBUG:-0}" = "1" ] && echo "[DEBUG] $*" >&2 || true; }
fi

# Default configuration
ISSUE=""
STATUS=""
REPO=""
WEBHOOK_PATH="/webhook/container-complete"
DRY_RUN=false
DEBUG=0

# Usage information
usage() {
    cat << EOF
container-complete-notifier.sh - Notify n8n webhook on container completion

USAGE:
    $0 --issue <N> --status <status> [OPTIONS]

OPTIONS:
    --issue <N>         Issue number (required)
    --status <status>   Completion status: success|failure|timeout (required)
    --repo <owner/repo> Repository name (default: from git remote)
    --webhook <path>    Webhook path (default: /webhook/container-complete)
    --dry-run           Print URL without sending request
    --debug             Enable debug logging
    --help              Show this help message

EXAMPLES:
    # Notify success from host
    $0 --issue 107 --status success

    # Notify failure from container
    $0 --issue 107 --status failure

    # Test URL detection without sending
    $0 --issue 107 --status success --dry-run

CONTEXT DETECTION:
    - Host:      Uses http://localhost:5678 (localhost binding)
    - Container: Uses http://n8n-<repo>:5678 (Docker DNS)

    Detection methods (in order):
    1. RUNNING_IN_CONTAINER environment variable
    2. /.dockerenv file existence
    3. /proc/1/cgroup content
EOF
}

# Detect if running in container
# Returns 0 if in container, 1 if on host
detect_container_context() {
    # Method 1: Explicit environment variable (most reliable)
    if [ "${RUNNING_IN_CONTAINER:-false}" = "true" ]; then
        log_debug "Detected container context via RUNNING_IN_CONTAINER env var"
        return 0
    fi

    # Method 2: Check for .dockerenv file (Docker-specific)
    if [ -f "/.dockerenv" ]; then
        log_debug "Detected container context via /.dockerenv file"
        return 0
    fi

    # Method 3: Check cgroup for docker/containerd
    if [ -f "/proc/1/cgroup" ]; then
        if grep -q -E 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
            log_debug "Detected container context via /proc/1/cgroup"
            return 0
        fi
    fi

    log_debug "Detected host context (not in container)"
    return 1
}

# Get n8n base URL based on context
get_n8n_url() {
    local port="${N8N_PORT:-5678}"

    if detect_container_context; then
        # Container context: use Docker DNS
        local repo_name="${REPO_NAME:-claude-agents}"
        local url="http://n8n-${repo_name}:${port}"
        log_debug "Container context detected, using: $url"
        echo "$url"
    else
        # Host context: use localhost
        local url="http://localhost:${port}"
        log_debug "Host context detected, using: $url"
        echo "$url"
    fi
}

# Extract repo name from owner/repo or git remote
get_repo_name() {
    local repo="$1"

    # If repo provided in owner/repo format, extract repo name
    if [ -n "$repo" ]; then
        echo "${repo##*/}"
        return 0
    fi

    # Try to get from REPO_NAME env var
    if [ -n "${REPO_NAME:-}" ]; then
        echo "$REPO_NAME"
        return 0
    fi

    # Try to get from git remote
    if command -v git &> /dev/null; then
        local remote_url
        remote_url=$(git remote get-url origin 2>/dev/null || echo "")
        if [ -n "$remote_url" ]; then
            # Extract repo name from URL (works for both https and git URLs)
            local repo_name
            repo_name=$(echo "$remote_url" | sed -E 's|.*/([^/]+)(\.git)?$|\1|')
            echo "$repo_name"
            return 0
        fi
    fi

    # Default fallback
    echo "claude-agents"
}

# Send webhook notification
send_webhook() {
    local issue="$1"
    local status="$2"
    local n8n_url="$3"
    local webhook_path="$4"

    local full_url="${n8n_url}${webhook_path}"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Build JSON payload
    local payload
    payload=$(jq -n \
        --arg issue "$issue" \
        --arg status "$status" \
        --arg timestamp "$timestamp" \
        --arg context "$(detect_container_context && echo 'container' || echo 'host')" \
        '{
            issue: ($issue | tonumber),
            status: $status,
            timestamp: $timestamp,
            context: $context
        }')

    log_debug "Webhook URL: $full_url"
    log_debug "Payload: $payload"

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN - Would send webhook to: $full_url"
        log_info "Payload: $payload"
        return 0
    fi

    # Send webhook with curl
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "$full_url" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || {
        log_error "Failed to send webhook request"
        return 1
    }

    # Extract HTTP code from last line
    http_code=$(echo "$response" | tail -n 1)
    local body
    body=$(echo "$response" | head -n -1)

    log_debug "HTTP response code: $http_code"
    log_debug "Response body: $body"

    # Check response
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_info "Webhook sent successfully (HTTP $http_code)"
        return 0
    else
        log_error "Webhook request failed (HTTP $http_code)"
        log_error "Response: $body"
        return 1
    fi
}

# Check if n8n is reachable
check_n8n_reachable() {
    local n8n_url="$1"
    local health_url="${n8n_url}/healthz"

    log_debug "Checking n8n health at: $health_url"

    # Try to reach health endpoint with short timeout
    if curl -s -f --max-time 5 "$health_url" > /dev/null 2>&1; then
        log_debug "n8n is reachable"
        return 0
    else
        log_warn "n8n not reachable at $health_url"
        return 1
    fi
}

# Main function
main() {
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --issue)
                ISSUE="$2"
                shift 2
                ;;
            --status)
                STATUS="$2"
                shift 2
                ;;
            --repo)
                REPO="$2"
                shift 2
                ;;
            --webhook)
                WEBHOOK_PATH="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --debug)
                DEBUG=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$ISSUE" ]; then
        log_error "--issue is required"
        usage
        exit 1
    fi

    if [ -z "$STATUS" ]; then
        log_error "--status is required"
        usage
        exit 1
    fi

    # Validate status value
    if [[ ! "$STATUS" =~ ^(success|failure|timeout)$ ]]; then
        log_error "Invalid status: $STATUS (must be success, failure, or timeout)"
        exit 1
    fi

    # Get repo name and set in environment for URL construction
    local repo_name
    repo_name=$(get_repo_name "$REPO")
    export REPO_NAME="$repo_name"
    log_debug "Repository name: $repo_name"

    # Get n8n URL based on context
    local n8n_url
    n8n_url=$(get_n8n_url)
    log_info "n8n URL: $n8n_url"

    # Check if n8n is reachable (skip if dry-run)
    if [ "$DRY_RUN" != true ]; then
        if ! check_n8n_reachable "$n8n_url"; then
            log_error "n8n is not reachable - webhook notification skipped"
            exit 2
        fi
    fi

    # Send webhook notification
    if send_webhook "$ISSUE" "$STATUS" "$n8n_url" "$WEBHOOK_PATH"; then
        log_info "Container completion notification sent for issue #$ISSUE (status: $STATUS)"
        exit 0
    else
        log_error "Failed to send container completion notification"
        exit 1
    fi
}

# Run main
main "$@"
