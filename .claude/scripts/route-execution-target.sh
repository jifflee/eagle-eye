#!/bin/bash
set -euo pipefail
# route-execution-target.sh
# Intelligent execution target routing: Proxmox → local Docker → worktree
# Part of feature #1326: Proxmox-first container routing with local and worktree fallback
#
# Implements the following decision tree (in priority order):
#   1. If --worktree flag passed → worktree (always respected)
#   2. If preferred_execution_target=proxmox → Proxmox (if available) or error
#   3. Check Proxmox availability and capacity:
#      a. Available + slots free            → proxmox
#      b. Available + backlog ≤ threshold   → proxmox (queue)
#      c. Available + backlog > threshold   → fall through to local
#      d. Unreachable / not configured      → fall through to local
#   4. Check local Docker:
#      a. Docker running + capacity (< 2)   → local
#      b. Docker unavailable / at capacity  → fall through to worktree
#   5. Worktree fallback
#
# Usage:
#   ./scripts/route-execution-target.sh [OPTIONS]
#
# Options:
#   --worktree            Force worktree mode (bypasses all routing)
#   --issue <N>           Issue number (used for logging context)
#   --verbose             Include full sub-check results in output
#   --dry-run             Simulate Proxmox as available (for testing)
#   --help                Show this help
#
# Output: JSON routing decision
# {
#   "target": "proxmox|local|worktree",
#   "reason": "explanation of why this target was chosen",
#   "checks": {
#     "proxmox": { ... },
#     "local_docker": { ... }
#   },
#   "config": {
#     "preferred_execution_target": "auto",
#     "proxmox_backlog_threshold": 4,
#     "proxmox_max_slots": 3,
#     "local_max_containers": 2
#   }
# }
#
# Exit codes:
#   0 - Success (routing decision made; check .target in output)
#   1 - Error (script misconfiguration)

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
# DEFAULTS
# ============================================================================

FORCE_WORKTREE=false
ISSUE_NUMBER=""
VERBOSE=false
DRY_RUN=false

LOCAL_MAX_CONTAINERS="${MAX_CONTAINERS_LOCAL:-2}"
PROXMOX_MAX_SLOTS="${MAX_CONTAINERS_PROXMOX:-3}"
PROXMOX_BACKLOG_THRESHOLD="${PROXMOX_BACKLOG_THRESHOLD:-4}"
PREFERRED_TARGET="${PREFERRED_EXECUTION_TARGET:-auto}"
CONTAINER_PREFIX="${FRAMEWORK_CONTAINER_PREFIX:-claude-agent-issue}"

# ============================================================================
# ARG PARSING
# ============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --worktree)
            FORCE_WORKTREE=true
            shift
            ;;
        --issue)
            ISSUE_NUMBER="$2"
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
            grep '^#' "$0" | head -50 | sed 's/^# \?//'
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

load_routing_config() {
    local config_file="${HOME}/.claude-tastic/config.json"

    if [ ! -f "$config_file" ] || ! command -v jq &>/dev/null; then
        return 0
    fi

    local cfg_pref cfg_backlog cfg_max_slots cfg_local_max
    cfg_pref=$(jq -r '.preferred_execution_target // ""' "$config_file" 2>/dev/null || echo "")
    cfg_backlog=$(jq -r '.proxmox.backlog_threshold // ""' "$config_file" 2>/dev/null || echo "")
    cfg_max_slots=$(jq -r '.proxmox.max_slots // ""' "$config_file" 2>/dev/null || echo "")
    cfg_local_max=$(jq -r '.local.max_containers // ""' "$config_file" 2>/dev/null || echo "")

    [ -n "$cfg_pref" ]      && PREFERRED_TARGET="$cfg_pref"
    [ -n "$cfg_backlog" ]   && PROXMOX_BACKLOG_THRESHOLD="$cfg_backlog"
    [ -n "$cfg_max_slots" ] && PROXMOX_MAX_SLOTS="$cfg_max_slots"
    [ -n "$cfg_local_max" ] && LOCAL_MAX_CONTAINERS="$cfg_local_max"

    log_debug "Routing config: preferred=${PREFERRED_TARGET}, proxmox_max=${PROXMOX_MAX_SLOTS}, backlog_threshold=${PROXMOX_BACKLOG_THRESHOLD}, local_max=${LOCAL_MAX_CONTAINERS}"
}

# ============================================================================
# HELPERS
# ============================================================================

# Get count of locally running sprint containers
get_local_container_count() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        docker ps --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null \
            | grep -c "^${CONTAINER_PREFIX}" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Check local Docker availability and capacity
check_local_docker() {
    local max_containers="$1"

    if ! command -v docker &>/dev/null; then
        echo '{"available": false, "reason": "Docker not installed", "running": 0, "max": 0, "has_capacity": false}'
        return 0
    fi

    if ! docker info &>/dev/null 2>&1; then
        echo '{"available": false, "reason": "Docker daemon not running", "running": 0, "max": 0, "has_capacity": false}'
        return 0
    fi

    local running_count
    running_count=$(get_local_container_count)

    local has_capacity=true
    local reason="Docker available (${running_count}/${max_containers} containers running)"

    if [ "$running_count" -ge "$max_containers" ]; then
        has_capacity=false
        reason="Docker at capacity: ${running_count}/${max_containers} containers running"
    fi

    jq -cn \
        --argjson available true \
        --argjson running "$running_count" \
        --argjson max "$max_containers" \
        --argjson has_capacity "$has_capacity" \
        --arg reason "$reason" \
        '{
          available: $available,
          reason: $reason,
          running: $running,
          max: $max,
          has_capacity: $has_capacity
        }'
}

# ============================================================================
# ROUTING LOGIC
# ============================================================================

route() {
    load_routing_config

    # ---- Step 0: Forced worktree ----
    if [ "$FORCE_WORKTREE" = "true" ]; then
        log_info "Target: worktree (--worktree flag passed)"
        emit_decision "worktree" "Forced worktree mode via --worktree flag" \
            '{}' '{}' "forced"
        return 0
    fi

    # ---- Step 1: Override if preferred_execution_target = worktree ----
    if [ "$PREFERRED_TARGET" = "worktree" ]; then
        log_info "Target: worktree (preferred_execution_target=worktree)"
        emit_decision "worktree" "preferred_execution_target is 'worktree'" \
            '{}' '{}' "config_override"
        return 0
    fi

    # ---- Step 2: Check Proxmox ----
    local proxmox_check='{}'
    local proxmox_args=()

    [ "$DRY_RUN" = "true" ] && proxmox_args+=("--dry-run")

    if [ -x "${SCRIPT_DIR}/check-proxmox-availability.sh" ]; then
        proxmox_check=$("${SCRIPT_DIR}/check-proxmox-availability.sh" "${proxmox_args[@]}" 2>/dev/null) \
            || proxmox_check='{"available": false, "reachable": false, "should_route_to_proxmox": false, "reason": "check script failed"}'
    else
        proxmox_check='{"available": false, "reachable": false, "should_route_to_proxmox": false, "reason": "check-proxmox-availability.sh not found"}'
    fi

    local should_route_proxmox proxmox_reason
    should_route_proxmox=$(echo "$proxmox_check" | jq -r '.should_route_to_proxmox // false')
    proxmox_reason=$(echo "$proxmox_check" | jq -r '.reason // "unknown"')

    # If preferred_execution_target=proxmox, force Proxmox or error
    if [ "$PREFERRED_TARGET" = "proxmox" ]; then
        if [ "$should_route_proxmox" = "true" ]; then
            log_info "Target: proxmox (preferred_execution_target=proxmox, available)"
            emit_decision "proxmox" "preferred_execution_target=proxmox — ${proxmox_reason}" \
                "$proxmox_check" '{}' "config_override"
        else
            log_warn "preferred_execution_target=proxmox but Proxmox unavailable — falling back to local"
            emit_decision "local" "preferred_execution_target=proxmox but unavailable: ${proxmox_reason} — falling back to local" \
                "$proxmox_check" '{}' "config_override_fallback"
        fi
        return 0
    fi

    # Auto-routing: route to Proxmox if available
    if [ "$should_route_proxmox" = "true" ]; then
        log_info "Target: proxmox — ${proxmox_reason}"
        emit_decision "proxmox" "$proxmox_reason" "$proxmox_check" '{}' "auto"
        return 0
    fi

    log_debug "Proxmox not selected: ${proxmox_reason}"

    # ---- Step 3: Check local Docker ----
    local local_check
    local_check=$(check_local_docker "$LOCAL_MAX_CONTAINERS")

    local docker_available docker_has_capacity local_reason
    docker_available=$(echo "$local_check" | jq -r '.available // false')
    docker_has_capacity=$(echo "$local_check" | jq -r '.has_capacity // false')
    local_reason=$(echo "$local_check" | jq -r '.reason // "unknown"')

    if [ "$docker_available" = "true" ] && [ "$docker_has_capacity" = "true" ]; then
        log_info "Target: local — ${local_reason}"
        emit_decision "local" "${local_reason} (Proxmox skipped: ${proxmox_reason})" \
            "$proxmox_check" "$local_check" "auto"
        return 0
    fi

    # ---- Step 4: Worktree fallback ----
    local fallback_reason
    if [ "$docker_available" = "false" ]; then
        fallback_reason="Docker unavailable — ${local_reason}"
    else
        fallback_reason="Docker at capacity — ${local_reason}"
    fi

    log_info "Target: worktree — ${fallback_reason}"
    emit_decision "worktree" "${fallback_reason} (Proxmox: ${proxmox_reason})" \
        "$proxmox_check" "$local_check" "auto"
}

# Emit the routing decision as JSON
emit_decision() {
    local target="$1"
    local reason="$2"
    local proxmox_check="$3"
    local local_check="$4"
    local decision_type="$5"

    if [ "$VERBOSE" = "true" ]; then
        jq -cn \
            --arg target "$target" \
            --arg reason "$reason" \
            --argjson proxmox_check "$proxmox_check" \
            --argjson local_check "$local_check" \
            --arg decision_type "$decision_type" \
            --arg preferred_target "$PREFERRED_TARGET" \
            --argjson proxmox_backlog_threshold "$PROXMOX_BACKLOG_THRESHOLD" \
            --argjson proxmox_max_slots "$PROXMOX_MAX_SLOTS" \
            --argjson local_max_containers "$LOCAL_MAX_CONTAINERS" \
            '{
              target: $target,
              reason: $reason,
              decision_type: $decision_type,
              checks: {
                proxmox: $proxmox_check,
                local_docker: $local_check
              },
              config: {
                preferred_execution_target: $preferred_target,
                proxmox_backlog_threshold: $proxmox_backlog_threshold,
                proxmox_max_slots: $proxmox_max_slots,
                local_max_containers: $local_max_containers
              }
            }'
    else
        jq -cn \
            --arg target "$target" \
            --arg reason "$reason" \
            --arg decision_type "$decision_type" \
            --arg preferred_target "$PREFERRED_TARGET" \
            --argjson proxmox_backlog_threshold "$PROXMOX_BACKLOG_THRESHOLD" \
            --argjson proxmox_max_slots "$PROXMOX_MAX_SLOTS" \
            --argjson local_max_containers "$LOCAL_MAX_CONTAINERS" \
            '{
              target: $target,
              reason: $reason,
              decision_type: $decision_type,
              config: {
                preferred_execution_target: $preferred_target,
                proxmox_backlog_threshold: $proxmox_backlog_threshold,
                proxmox_max_slots: $proxmox_max_slots,
                local_max_containers: $local_max_containers
              }
            }'
    fi
}

# ============================================================================
# ENTRY POINT
# ============================================================================

route
