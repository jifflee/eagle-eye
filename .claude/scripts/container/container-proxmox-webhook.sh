#!/bin/bash
set -euo pipefail
# container-proxmox-webhook.sh
# Report container status back to n8n running on Proxmox (Issue #819)
#
# Containers on docker-workers call back to n8n on the Proxmox n8n VM.
# This script handles cross-VM webhook notifications including:
#   - Heartbeat: periodic liveness updates while container is running
#   - Status: phase/action updates for monitoring
#   - Completion: final result (success/failure/timeout) with PR info
#
# Unlike container-complete-notifier.sh which uses Docker DNS for localhost n8n,
# this script targets n8n on a different Proxmox VM by IP/hostname.
#
# Usage:
#   ./scripts/container-proxmox-webhook.sh heartbeat [OPTIONS]
#   ./scripts/container-proxmox-webhook.sh status [OPTIONS]
#   ./scripts/container-proxmox-webhook.sh complete [OPTIONS]
#
# Options:
#   --issue <N>           Issue number (required)
#   --status <status>     Status: success|failure|timeout|running|starting
#   --phase <phase>       Current phase (for heartbeat/status)
#   --action <action>     Current action description
#   --pr-url <url>        PR URL (for completion events)
#   --pr-number <N>       PR number (for completion events)
#   --exit-code <N>       Container exit code (for completion events)
#   --duration <sec>      Duration in seconds (for completion events)
#   --n8n-url <url>       Override n8n URL (default: from env N8N_PROXMOX_URL)
#   --dry-run             Show what would be sent without sending
#   --debug               Enable debug logging
#   --help                Show this help
#
# Environment Variables:
#   N8N_PROXMOX_URL       n8n URL on Proxmox (e.g., http://10.69.5.20:5678)
#   WEBHOOK_URL           Fallback n8n URL (generic webhook base URL)
#   ISSUE                 Issue number (set by container entrypoint)
#   REPO_FULL_NAME        Repository (owner/repo)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities if available
if [ -f "${SCRIPT_DIR}/../lib/common.sh" ]; then
    source "${SCRIPT_DIR}/../lib/common.sh"
else
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { [ "${DEBUG:-0}" = "1" ] && echo "[DEBUG] $*" >&2 || true; }
fi

# Script metadata
SCRIPT_NAME="container-proxmox-webhook.sh"
VERSION="1.0.0"

# Defaults
EVENT_TYPE=""
ISSUE="${ISSUE:-}"
STATUS=""
PHASE=""
ACTION=""
PR_URL=""
PR_NUMBER=""
EXIT_CODE=""
DURATION_SECONDS=""
DRY_RUN="false"
TIMEOUT_SECS=10

# Determine n8n URL for Proxmox
# Priority: --n8n-url arg > N8N_PROXMOX_URL env > WEBHOOK_URL env > default
get_n8n_url() {
    local override="${1:-}"

    if [ -n "$override" ]; then
        echo "$override"
        return 0
    fi

    # N8N_PROXMOX_URL is set by proxmox-n8n-setup.sh on docker-workers
    if [ -n "${N8N_PROXMOX_URL:-}" ]; then
        log_debug "Using N8N_PROXMOX_URL: ${N8N_PROXMOX_URL}"
        echo "${N8N_PROXMOX_URL}"
        return 0
    fi

    # Fallback to WEBHOOK_URL if set (may be Proxmox URL already)
    if [ -n "${WEBHOOK_URL:-}" ]; then
        log_debug "Using WEBHOOK_URL: ${WEBHOOK_URL}"
        echo "${WEBHOOK_URL}"
        return 0
    fi

    # Last resort: try to detect n8n on local Docker network
    # In containers on docker-workers, n8n is on the Proxmox VM (not local)
    log_warn "N8N_PROXMOX_URL not set - webhook callbacks may not work"
    log_warn "Set N8N_PROXMOX_URL in /opt/apps/claude-workers/.env"
    log_warn "Run: ./scripts/proxmox-n8n-setup.sh to configure"
    echo ""
}

# Check if n8n is reachable
check_n8n_reachable() {
    local url="$1"

    if [ -z "$url" ]; then
        return 1
    fi

    log_debug "Checking n8n reachability: ${url}/healthz"
    if curl -sf --max-time "${TIMEOUT_SECS}" "${url}/healthz" > /dev/null 2>&1; then
        log_debug "n8n is reachable"
        return 0
    fi
    return 1
}

# Send webhook to Proxmox n8n
send_webhook() {
    local webhook_path="$1"
    local payload="$2"
    local n8n_url="$3"

    if [ -z "$n8n_url" ]; then
        log_warn "No n8n URL available - skipping webhook notification"
        return 1
    fi

    local full_url="${n8n_url}${webhook_path}"
    log_debug "Sending webhook to: ${full_url}"
    log_debug "Payload: ${payload}"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would POST to: ${full_url}"
        log_info "[DRY-RUN] Payload: ${payload}"
        return 0
    fi

    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "${full_url}" \
        -H "Content-Type: application/json" \
        --max-time "${TIMEOUT_SECS}" \
        -d "${payload}" 2>&1) || {
        log_warn "Webhook request failed (network error or timeout)"
        return 1
    }

    http_code=$(echo "$response" | tail -n 1)
    local body
    body=$(echo "$response" | head -n -1)

    log_debug "HTTP response: ${http_code}"

    if [ "${http_code:-0}" -ge 200 ] && [ "${http_code:-0}" -lt 300 ]; then
        log_debug "Webhook sent successfully (HTTP ${http_code})"
        return 0
    else
        log_warn "Webhook returned HTTP ${http_code}: ${body}"
        return 1
    fi
}

# Build heartbeat payload and send
send_heartbeat() {
    local n8n_url
    n8n_url=$(get_n8n_url "${N8N_URL_OVERRIDE:-}")

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local container_name="claude-tastic-issue-${ISSUE}"
    local remote_host
    remote_host=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

    # Get Claude process metrics if available
    local claude_cpu=0
    local claude_mem=0
    local claude_pid
    claude_pid=$(pgrep -f "claude" 2>/dev/null | head -1 || echo "")
    if [ -n "$claude_pid" ]; then
        local ps_output
        ps_output=$(ps -p "$claude_pid" -o %cpu,%mem --no-headers 2>/dev/null || echo "0 0")
        claude_cpu=$(echo "$ps_output" | awk '{print $1}')
        claude_mem=$(echo "$ps_output" | awk '{print $2}')
    fi

    local payload
    payload=$(cat << EOF
{
  "event_type": "heartbeat",
  "issue": ${ISSUE:-0},
  "container_name": "${container_name}",
  "phase": "${PHASE:-running}",
  "action": "${ACTION:-processing}",
  "timestamp": "${timestamp}",
  "remote_host": "${remote_host}",
  "uptime_seconds": ${SECONDS:-0},
  "claude_cpu": ${claude_cpu:-0},
  "claude_mem": ${claude_mem:-0},
  "repo": "${REPO_FULL_NAME:-}"
}
EOF
)

    send_webhook "/webhook/container-heartbeat" "$payload" "$n8n_url" || true
    log_debug "Heartbeat sent for issue #${ISSUE}"
}

# Build status update payload and send
send_status_update() {
    local n8n_url
    n8n_url=$(get_n8n_url "${N8N_URL_OVERRIDE:-}")

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local remote_host
    remote_host=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

    local payload
    payload=$(cat << EOF
{
  "event_type": "status",
  "issue": ${ISSUE:-0},
  "status": "${STATUS:-running}",
  "phase": "${PHASE:-}",
  "action": "${ACTION:-}",
  "timestamp": "${timestamp}",
  "remote_host": "${remote_host}",
  "repo": "${REPO_FULL_NAME:-}"
}
EOF
)

    if ! send_webhook "/webhook/container-status" "$payload" "$n8n_url"; then
        log_warn "Status update webhook failed (non-fatal)"
    fi
}

# Build completion payload and send
send_completion() {
    local n8n_url
    n8n_url=$(get_n8n_url "${N8N_URL_OVERRIDE:-}")

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local container_name="claude-tastic-issue-${ISSUE}"
    local remote_host
    remote_host=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

    # Build payload with optional PR info
    local payload
    payload=$(cat << EOF
{
  "event_type": "completion",
  "issue": ${ISSUE:-0},
  "status": "${STATUS:-unknown}",
  "container_name": "${container_name}",
  "remote_host": "${remote_host}",
  "exit_code": ${EXIT_CODE:--1},
  "duration_seconds": ${DURATION_SECONDS:-0},
  "timestamp": "${timestamp}",
  "repo": "${REPO_FULL_NAME:-}",
  "pr_url": ${PR_URL:+'"'"${PR_URL}"'"'},
  "pr_number": ${PR_NUMBER:-null}
}
EOF
)

    # Handle null pr_url correctly
    if [ -z "$PR_URL" ]; then
        payload=$(echo "$payload" | sed 's/"pr_url": ,/"pr_url": null,/')
    fi

    log_info "Sending completion notification (status: ${STATUS}) for issue #${ISSUE}"

    if send_webhook "/webhook/container-complete" "$payload" "$n8n_url"; then
        log_info "✓ Completion webhook sent to Proxmox n8n"
    else
        log_warn "Failed to send completion webhook (n8n may not be reachable from docker-workers)"
        log_warn "Container completed with status: ${STATUS}"
        # Don't fail - container completion is the primary goal
    fi
}

# Usage
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Report container status to n8n on Proxmox

USAGE:
    $SCRIPT_NAME <event> [OPTIONS]

EVENTS:
    heartbeat       Send periodic liveness heartbeat
    status          Send status/phase update
    complete        Send completion notification

OPTIONS:
    --issue <N>           Issue number (required; also from ISSUE env var)
    --status <status>     Status value (running|success|failure|timeout)
    --phase <phase>       Current execution phase
    --action <action>     Current action description
    --pr-url <url>        PR URL (for completion events)
    --pr-number <N>       PR number (for completion events)
    --exit-code <N>       Exit code (for completion events)
    --duration <sec>      Execution duration in seconds
    --n8n-url <url>       Override n8n URL
    --timeout <sec>       HTTP timeout in seconds (default: 10)
    --dry-run             Show payload without sending
    --debug               Enable debug logging
    --help                Show this help

ENVIRONMENT VARIABLES:
    N8N_PROXMOX_URL       n8n URL on Proxmox VM (set by proxmox-n8n-setup.sh)
    WEBHOOK_URL           Fallback n8n base URL
    ISSUE                 Issue number (set by container entrypoint)
    REPO_FULL_NAME        Repository full name

EXAMPLES:
    # Send heartbeat
    $SCRIPT_NAME heartbeat --issue 107 --phase implementing --action "writing tests"

    # Send status update
    $SCRIPT_NAME status --issue 107 --status running --phase "code review"

    # Send completion (success with PR)
    $SCRIPT_NAME complete --issue 107 --status success --pr-url https://github.com/... --exit-code 0

    # Send completion (failure)
    $SCRIPT_NAME complete --issue 107 --status failure --exit-code 1

    # Test without sending
    $SCRIPT_NAME heartbeat --issue 107 --dry-run

INTEGRATION:
    This script is called from container-sprint-workflow.sh at key lifecycle points.
    The N8N_PROXMOX_URL must be set in /opt/apps/claude-workers/.env on docker-workers.
    Use proxmox-n8n-setup.sh to configure this automatically.

EOF
}

# Main function
main() {
    # First argument is the event type
    if [ $# -eq 0 ]; then
        log_error "Event type required: heartbeat, status, or complete"
        usage
        exit 1
    fi

    EVENT_TYPE="$1"
    shift

    # Parse options
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
            --phase)
                PHASE="$2"
                shift 2
                ;;
            --action)
                ACTION="$2"
                shift 2
                ;;
            --pr-url)
                PR_URL="$2"
                shift 2
                ;;
            --pr-number)
                PR_NUMBER="$2"
                shift 2
                ;;
            --exit-code)
                EXIT_CODE="$2"
                shift 2
                ;;
            --duration)
                DURATION_SECONDS="$2"
                shift 2
                ;;
            --n8n-url)
                N8N_URL_OVERRIDE="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT_SECS="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --debug)
                DEBUG="1"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --version|-v)
                echo "$SCRIPT_NAME v$VERSION"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Validate issue number
    if [ -z "$ISSUE" ]; then
        log_error "--issue is required (or set ISSUE environment variable)"
        exit 1
    fi

    # Dispatch event
    case "$EVENT_TYPE" in
        heartbeat)
            send_heartbeat
            ;;
        status)
            [ -z "$STATUS" ] && STATUS="running"
            send_status_update
            ;;
        complete|completion)
            if [ -z "$STATUS" ]; then
                log_error "--status is required for completion events"
                exit 1
            fi
            send_completion
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown event type: ${EVENT_TYPE} (use: heartbeat, status, complete)"
            usage
            exit 1
            ;;
    esac
}

# Run main
main "$@"
