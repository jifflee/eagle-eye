#!/bin/bash
set -euo pipefail
# check-proxmox-availability.sh
# Checks Proxmox host connectivity, container slot usage, and backlog depth
# Part of feature #1326: Proxmox-first container routing with local and worktree fallback
#
# Usage:
#   ./scripts/check-proxmox-availability.sh [OPTIONS]
#
# Options:
#   --host <host>         Proxmox host to check (overrides config/env)
#   --api-port <port>     Proxmox API port (default: 8006)
#   --ssh-port <port>     SSH port (default: 22)
#   --timeout <sec>       Connection timeout (default: 5)
#   --verbose             Include detailed metrics in output
#   --dry-run             Simulate availability (for testing)
#   --help                Show this help
#
# Output: JSON with availability status and capacity metrics
# {
#   "available": true/false,
#   "reachable": true/false,
#   "check_method": "api|ssh|ping|none",
#   "slots": {
#     "running": 1,
#     "max": 3,
#     "available": 2
#   },
#   "backlog": {
#     "queued": 0,
#     "threshold": 4,
#     "within_threshold": true
#   },
#   "should_route_to_proxmox": true/false,
#   "reason": "explanation"
# }
#
# Exit codes:
#   0 - Success (check completed, output is valid JSON)
#   1 - Error (configuration or runtime failure)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities if available
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/common.sh"
else
    log_info()  { echo "[INFO]  $*" >&2; }
    log_warn()  { echo "[WARN]  $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { [ "${DEBUG:-0}" = "1" ] && echo "[DEBUG] $*" >&2 || true; }
fi

# ============================================================================
# CONFIGURATION — resolved in priority order:
#   1. CLI args
#   2. Environment variables
#   3. ~/.claude-tastic/config.json
#   4. Defaults
# ============================================================================

PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_API_PORT="8006"
PROXMOX_SSH_PORT="22"
TIMEOUT_SECS=5
VERBOSE=false
DRY_RUN=false

# Defaults (may be overridden by config or env)
DEFAULT_MAX_SLOTS=3
DEFAULT_BACKLOG_THRESHOLD=4
PROXMOX_CONTAINER_PREFIX="${FRAMEWORK_CONTAINER_PREFIX:-claude-agent-issue}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            PROXMOX_HOST="$2"
            shift 2
            ;;
        --api-port)
            PROXMOX_API_PORT="$2"
            shift 2
            ;;
        --ssh-port)
            PROXMOX_SSH_PORT="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT_SECS="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            grep '^#' "$0" | head -40 | sed 's/^# \?//'
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ============================================================================
# LOAD CONFIG from ~/.claude-tastic/config.json
# ============================================================================

load_config() {
    local config_file="${HOME}/.claude-tastic/config.json"

    if [ ! -f "$config_file" ]; then
        log_debug "No config file at ${config_file}"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_warn "jq not available — skipping config file"
        return 0
    fi

    # Load Proxmox host if not set via CLI
    if [ -z "$PROXMOX_HOST" ]; then
        PROXMOX_HOST=$(jq -r '.proxmox.host // ""' "$config_file" 2>/dev/null || echo "")
    fi

    # Load API port override
    local cfg_api_port
    cfg_api_port=$(jq -r '.proxmox.api_port // ""' "$config_file" 2>/dev/null || echo "")
    [ -n "$cfg_api_port" ] && PROXMOX_API_PORT="$cfg_api_port"

    # Load SSH port override
    local cfg_ssh_port
    cfg_ssh_port=$(jq -r '.proxmox.ssh_port // ""' "$config_file" 2>/dev/null || echo "")
    [ -n "$cfg_ssh_port" ] && PROXMOX_SSH_PORT="$cfg_ssh_port"

    # Load max slots
    local cfg_max_slots
    cfg_max_slots=$(jq -r '.proxmox.max_slots // ""' "$config_file" 2>/dev/null || echo "")
    [ -n "$cfg_max_slots" ] && DEFAULT_MAX_SLOTS="$cfg_max_slots"

    # Load backlog threshold
    local cfg_backlog
    cfg_backlog=$(jq -r '.proxmox.backlog_threshold // ""' "$config_file" 2>/dev/null || echo "")
    [ -n "$cfg_backlog" ] && DEFAULT_BACKLOG_THRESHOLD="$cfg_backlog"

    log_debug "Config loaded: host=${PROXMOX_HOST}, max_slots=${DEFAULT_MAX_SLOTS}, backlog_threshold=${DEFAULT_BACKLOG_THRESHOLD}"
}

# ============================================================================
# PROXMOX CONNECTIVITY CHECKS
# ============================================================================

# Check if Proxmox API endpoint is reachable (port 8006)
check_proxmox_api() {
    local host="$1"
    local port="${PROXMOX_API_PORT}"

    log_debug "Checking Proxmox API at ${host}:${port}"

    # Try curl to the Proxmox API health endpoint
    if command -v curl &>/dev/null; then
        if curl -sk --max-time "${TIMEOUT_SECS}" \
            "https://${host}:${port}/api2/json/version" \
            -o /dev/null 2>/dev/null; then
            log_debug "Proxmox API reachable via HTTPS"
            echo "api"
            return 0
        fi
    fi

    # Try TCP port check as fallback
    if command -v nc &>/dev/null; then
        if nc -z -w "${TIMEOUT_SECS}" "$host" "$port" 2>/dev/null; then
            log_debug "Proxmox API port reachable via TCP"
            echo "api_port"
            return 0
        fi
    fi

    return 1
}

# Check if Proxmox host is reachable via SSH
check_proxmox_ssh() {
    local host="$1"

    log_debug "Checking Proxmox SSH at ${host}:${PROXMOX_SSH_PORT}"

    if command -v ssh &>/dev/null; then
        if ssh -o StrictHostKeyChecking=no \
               -o ConnectTimeout="${TIMEOUT_SECS}" \
               -o BatchMode=yes \
               -p "${PROXMOX_SSH_PORT}" \
               "${host}" "echo ok" &>/dev/null; then
            log_debug "Proxmox SSH reachable"
            echo "ssh"
            return 0
        fi
    fi

    return 1
}

# Check if Proxmox host is reachable via ICMP ping
check_proxmox_ping() {
    local host="$1"

    log_debug "Pinging Proxmox host ${host}"

    if command -v ping &>/dev/null; then
        if ping -c 1 -W "${TIMEOUT_SECS}" "$host" &>/dev/null; then
            log_debug "Proxmox host reachable via ping"
            echo "ping"
            return 0
        fi
    fi

    return 1
}

# Returns the check method used, or empty string if unreachable
probe_proxmox_host() {
    local host="$1"
    local method=""

    # Try API first (most reliable)
    method=$(check_proxmox_api "$host") && { echo "$method"; return 0; } || true
    # Try SSH
    method=$(check_proxmox_ssh "$host") && { echo "$method"; return 0; } || true
    # Try ping as last resort
    method=$(check_proxmox_ping "$host") && { echo "$method"; return 0; } || true

    return 1
}

# ============================================================================
# PROXMOX CAPACITY QUERIES
# ============================================================================

# Query running container count on Proxmox via SSH
# Falls back to estimating from known container names if API is unavailable
query_proxmox_running_slots() {
    local host="$1"

    # If SSH is available, try to count running containers on Proxmox docker-workers
    if command -v ssh &>/dev/null; then
        local count
        count=$(ssh -o StrictHostKeyChecking=no \
                    -o ConnectTimeout="${TIMEOUT_SECS}" \
                    -o BatchMode=yes \
                    -p "${PROXMOX_SSH_PORT}" \
                    "${host}" \
                    "docker ps --filter 'name=${PROXMOX_CONTAINER_PREFIX}' --format '{{.Names}}' 2>/dev/null | grep -c '^${PROXMOX_CONTAINER_PREFIX}' || echo 0" \
                    2>/dev/null) || count=""

        if [[ "$count" =~ ^[0-9]+$ ]]; then
            echo "$count"
            return 0
        fi
    fi

    # Proxmox API query for running LXC containers (requires API token)
    local api_token="${PROXMOX_API_TOKEN:-}"
    if [ -n "$api_token" ] && command -v curl &>/dev/null; then
        local response
        response=$(curl -sk --max-time "${TIMEOUT_SECS}" \
            -H "Authorization: PVEAPIToken=${api_token}" \
            "https://${host}:${PROXMOX_API_PORT}/api2/json/cluster/resources?type=lxc" \
            2>/dev/null) || response=""

        if [ -n "$response" ]; then
            local running_count
            running_count=$(echo "$response" | jq -r '[.data[] | select(.status == "running")] | length' 2>/dev/null || echo "")
            if [[ "$running_count" =~ ^[0-9]+$ ]]; then
                echo "$running_count"
                return 0
            fi
        fi
    fi

    # Could not query — return -1 to indicate unknown
    echo "-1"
}

# Query backlog (queued/waiting containers) on Proxmox via SSH
query_proxmox_backlog() {
    local host="$1"

    if command -v ssh &>/dev/null; then
        # Count containers in "created" or "paused" state (waiting for slot)
        local count
        count=$(ssh -o StrictHostKeyChecking=no \
                    -o ConnectTimeout="${TIMEOUT_SECS}" \
                    -o BatchMode=yes \
                    -p "${PROXMOX_SSH_PORT}" \
                    "${host}" \
                    "docker ps -a --filter 'name=${PROXMOX_CONTAINER_PREFIX}' --filter 'status=created' --filter 'status=paused' --format '{{.Names}}' 2>/dev/null | wc -l || echo 0" \
                    2>/dev/null) || count=""

        if [[ "$count" =~ ^[0-9]+$ ]]; then
            echo "$count"
            return 0
        fi
    fi

    # Could not query — return -1 to indicate unknown
    echo "-1"
}

# ============================================================================
# DRY-RUN MODE (for testing without real Proxmox)
# ============================================================================

dry_run_output() {
    local pref_target="${PREFERRED_EXECUTION_TARGET:-auto}"

    # When in dry-run mode, simulate a healthy Proxmox with available slots
    jq -cn \
        --arg host "${PROXMOX_HOST:-proxmox-sim}" \
        --arg method "dry_run" \
        --argjson max_slots "${DEFAULT_MAX_SLOTS}" \
        --argjson backlog_threshold "${DEFAULT_BACKLOG_THRESHOLD}" \
        --arg preferred_target "$pref_target" \
        '{
          available: true,
          reachable: true,
          check_method: $method,
          host: $host,
          slots: {
            running: 0,
            max: $max_slots,
            available: $max_slots
          },
          backlog: {
            queued: 0,
            threshold: $backlog_threshold,
            within_threshold: true
          },
          should_route_to_proxmox: true,
          reason: "Dry-run mode: Proxmox simulated as available with capacity",
          preferred_execution_target: $preferred_target
        }'
    exit 0
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    load_config

    # Override with environment variables (lower priority than CLI args)
    [ -z "$PROXMOX_HOST" ] && PROXMOX_HOST="${PROXMOX_HOST:-}"

    # Check preferred execution target setting
    PREFERRED_TARGET="${PREFERRED_EXECUTION_TARGET:-auto}"
    if [ -f "${HOME}/.claude-tastic/config.json" ] && command -v jq &>/dev/null; then
        cfg_pref=$(jq -r '.preferred_execution_target // ""' "${HOME}/.claude-tastic/config.json" 2>/dev/null || echo "")
        [ -n "$cfg_pref" ] && PREFERRED_TARGET="$cfg_pref"
    fi

    # Handle dry-run mode
    if [ "$DRY_RUN" = "true" ]; then
        dry_run_output
    fi

    # If preferred target is explicitly "local" or "worktree", skip Proxmox check
    if [ "$PREFERRED_TARGET" = "local" ] || [ "$PREFERRED_TARGET" = "worktree" ]; then
        local skip_reason="preferred_execution_target is set to '${PREFERRED_TARGET}' — Proxmox skipped"
        jq -cn \
            --arg target "$PREFERRED_TARGET" \
            --arg reason "$skip_reason" \
            '{
              available: false,
              reachable: false,
              check_method: "skipped",
              host: null,
              slots: { running: 0, max: 0, available: 0 },
              backlog: { queued: 0, threshold: 4, within_threshold: true },
              should_route_to_proxmox: false,
              reason: $reason,
              preferred_execution_target: $target
            }'
        exit 0
    fi

    # No Proxmox host configured → not available
    if [ -z "$PROXMOX_HOST" ]; then
        jq -cn \
            --argjson backlog_threshold "${DEFAULT_BACKLOG_THRESHOLD}" \
            '{
              available: false,
              reachable: false,
              check_method: "none",
              host: null,
              slots: { running: 0, max: 0, available: 0 },
              backlog: { queued: 0, threshold: $backlog_threshold, within_threshold: true },
              should_route_to_proxmox: false,
              reason: "Proxmox host not configured (set PROXMOX_HOST or ~/.claude-tastic/config.json .proxmox.host)",
              preferred_execution_target: "auto"
            }'
        exit 0
    fi

    log_debug "Checking Proxmox host: ${PROXMOX_HOST}"

    # ---- Connectivity check ----
    CHECK_METHOD=""
    REACHABLE=false

    if CHECK_METHOD=$(probe_proxmox_host "$PROXMOX_HOST"); then
        REACHABLE=true
        log_debug "Proxmox reachable via: ${CHECK_METHOD}"
    else
        log_debug "Proxmox host unreachable: ${PROXMOX_HOST}"
    fi

    if [ "$REACHABLE" = "false" ]; then
        jq -cn \
            --arg host "$PROXMOX_HOST" \
            --argjson max_slots "${DEFAULT_MAX_SLOTS}" \
            --argjson backlog_threshold "${DEFAULT_BACKLOG_THRESHOLD}" \
            --arg preferred_target "$PREFERRED_TARGET" \
            '{
              available: false,
              reachable: false,
              check_method: "none",
              host: $host,
              slots: { running: 0, max: $max_slots, available: $max_slots },
              backlog: { queued: 0, threshold: $backlog_threshold, within_threshold: true },
              should_route_to_proxmox: false,
              reason: ("Proxmox host unreachable: " + $host),
              preferred_execution_target: $preferred_target
            }'
        exit 0
    fi

    # ---- Capacity check ----
    RUNNING_SLOTS=$(query_proxmox_running_slots "$PROXMOX_HOST")
    QUEUED_COUNT=$(query_proxmox_backlog "$PROXMOX_HOST")

    # If capacity query failed (-1), assume capacity available for connectivity check
    SLOTS_UNKNOWN=false
    if [ "$RUNNING_SLOTS" = "-1" ]; then
        RUNNING_SLOTS=0
        SLOTS_UNKNOWN=true
        log_debug "Could not query Proxmox slot usage — assuming available"
    fi

    if [ "$QUEUED_COUNT" = "-1" ]; then
        QUEUED_COUNT=0
        log_debug "Could not query Proxmox backlog — assuming empty"
    fi

    MAX_SLOTS="${DEFAULT_MAX_SLOTS}"
    BACKLOG_THRESHOLD="${DEFAULT_BACKLOG_THRESHOLD}"

    AVAILABLE_SLOTS=$(( MAX_SLOTS - RUNNING_SLOTS ))
    [ "$AVAILABLE_SLOTS" -lt 0 ] && AVAILABLE_SLOTS=0

    WITHIN_BACKLOG_THRESHOLD=true
    [ "$QUEUED_COUNT" -gt "$BACKLOG_THRESHOLD" ] && WITHIN_BACKLOG_THRESHOLD=false

    # Routing decision
    SHOULD_ROUTE=false
    REASON=""

    if [ "$AVAILABLE_SLOTS" -gt 0 ]; then
        SHOULD_ROUTE=true
        REASON="Proxmox available with ${AVAILABLE_SLOTS} slot(s) free (${RUNNING_SLOTS}/${MAX_SLOTS} running)"
    elif [ "$WITHIN_BACKLOG_THRESHOLD" = "true" ]; then
        SHOULD_ROUTE=true
        REASON="Proxmox at capacity (${RUNNING_SLOTS}/${MAX_SLOTS}) but backlog (${QUEUED_COUNT}) is within threshold (${BACKLOG_THRESHOLD}) — queuing on Proxmox"
    else
        SHOULD_ROUTE=false
        REASON="Proxmox at capacity (${RUNNING_SLOTS}/${MAX_SLOTS}) and backlog (${QUEUED_COUNT}) exceeds threshold (${BACKLOG_THRESHOLD}) — falling back to local"
    fi

    if [ "$SLOTS_UNKNOWN" = "true" ]; then
        REASON="${REASON} [slot count estimated — SSH/API query unavailable]"
    fi

    log_debug "Routing decision: should_route_to_proxmox=${SHOULD_ROUTE}, reason=${REASON}"

    jq -cn \
        --arg host "$PROXMOX_HOST" \
        --arg method "$CHECK_METHOD" \
        --argjson running "$RUNNING_SLOTS" \
        --argjson max_slots "$MAX_SLOTS" \
        --argjson available "$AVAILABLE_SLOTS" \
        --argjson queued "$QUEUED_COUNT" \
        --argjson threshold "$BACKLOG_THRESHOLD" \
        --argjson within_threshold "$WITHIN_BACKLOG_THRESHOLD" \
        --argjson should_route "$SHOULD_ROUTE" \
        --arg reason "$REASON" \
        --arg preferred_target "$PREFERRED_TARGET" \
        '{
          available: true,
          reachable: true,
          check_method: $method,
          host: $host,
          slots: {
            running: $running,
            max: $max_slots,
            available: $available
          },
          backlog: {
            queued: $queued,
            threshold: $threshold,
            within_threshold: $within_threshold
          },
          should_route_to_proxmox: $should_route,
          reason: $reason,
          preferred_execution_target: $preferred_target
        }'
}

main "$@"
