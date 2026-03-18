#!/bin/bash
set -euo pipefail
# check-llm-availability.sh
# LLM availability checking and decision logic for autonomous task orchestration
# Part of feature #750: Implement LLM availability checking and decision logic
# Parent epic: #263 - Multi-LLM Task Orchestrator
#
# This script checks if LLM providers (primarily Claude Code) are available for
# task execution by verifying token capacity, system resources, and operational status.
#
# Usage:
#   ./scripts/check-llm-availability.sh [OPTIONS]
#
# Options:
#   --provider <name>    Check specific provider (default: claude)
#   --verbose            Include detailed check results in output
#   --thresholds <json>  Override default thresholds (JSON format)
#
# Output: JSON with availability decision and detailed status
# {
#   "available": true/false,
#   "provider": "claude",
#   "reason": "explanation",
#   "checks": {
#     "token_capacity": { "passed": true, ... },
#     "resource_capacity": { "passed": true, ... },
#     "operational_status": { "passed": true, ... }
#   },
#   "decision": "trigger|skip",
#   "timestamp": "2024-..."
# }
#
# Exit codes:
#   0 - Success (check completed, provider available or unavailable)
#   1 - Error (missing dependencies, invalid arguments)
#   2 - Configuration error

set -e

# Script metadata
SCRIPT_NAME="check-llm-availability.sh"
VERSION="1.0.0"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT="."

# Source shared logging utilities
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
  source "${SCRIPT_DIR}/lib/common.sh"
else
  # Minimal fallback logging if common.sh not available
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_success() { echo "[OK] $*" >&2; }
  log_debug() { [ -n "${DEBUG:-}" ] && echo "[DEBUG] $*" >&2 || true; }
  require_command() { command -v "$1" &>/dev/null || { log_error "Required command not found: $1"; exit 1; }; }
fi

# Default configuration
PROVIDER="claude"
VERBOSE=false
CUSTOM_THRESHOLDS=""

# Default thresholds (can be overridden via --thresholds or environment)
TOKEN_CHECK_ENABLED="${LLM_TOKEN_CHECK_ENABLED:-true}"
RESOURCE_CHECK_ENABLED="${LLM_RESOURCE_CHECK_ENABLED:-true}"
OPERATIONAL_CHECK_ENABLED="${LLM_OPERATIONAL_CHECK_ENABLED:-true}"

# Token capacity thresholds
SESSION_TOKEN_LIMIT="${CLAUDE_SESSION_TOKEN_LIMIT:-500000}"
WEEKLY_TOKEN_LIMIT="${CLAUDE_WEEKLY_TOKEN_LIMIT:-5000000}"
TOKEN_SAFETY_MARGIN="${LLM_TOKEN_SAFETY_MARGIN:-10}"  # Leave 10% margin

# Resource capacity thresholds
CPU_MAX_THRESHOLD="${CONTAINER_CPU_MAX_THRESHOLD:-80}"
MEMORY_MAX_THRESHOLD="${CONTAINER_MEMORY_MAX_THRESHOLD:-85}"

# Operational status thresholds
MAX_CONCURRENT_CONTAINERS="${LLM_MAX_CONCURRENT:-2}"

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - LLM Availability Checker

USAGE:
    $SCRIPT_NAME [OPTIONS]

DESCRIPTION:
    Checks LLM provider availability for autonomous task execution.
    Performs comprehensive checks on token capacity, system resources,
    and operational status to determine if work can be triggered.

OPTIONS:
    --provider <name>       Provider to check (default: claude)
                           Supported: claude

    --verbose              Include detailed check results in JSON output

    --thresholds <json>    Override default thresholds with JSON config
                           Example: '{"cpu_max":75,"memory_max":80}'

    --debug                Enable debug logging

    --help, -h             Show this help message

ENVIRONMENT VARIABLES:
    LLM_TOKEN_CHECK_ENABLED        Enable/disable token capacity check (default: true)
    LLM_RESOURCE_CHECK_ENABLED     Enable/disable resource capacity check (default: true)
    LLM_OPERATIONAL_CHECK_ENABLED  Enable/disable operational status check (default: true)

    CLAUDE_SESSION_TOKEN_LIMIT     Session token limit (default: 500000)
    CLAUDE_WEEKLY_TOKEN_LIMIT      Weekly token limit (default: 5000000)
    LLM_TOKEN_SAFETY_MARGIN        Token safety margin % (default: 10)

    CONTAINER_CPU_MAX_THRESHOLD    Max CPU usage % (default: 80)
    CONTAINER_MEMORY_MAX_THRESHOLD Max memory usage % (default: 85)
    LLM_MAX_CONCURRENT             Max concurrent containers (default: 2)

OUTPUT:
    JSON object with availability status, reason, and detailed checks.
    Exit code 0 indicates successful check (regardless of availability).

EXAMPLES:
    # Basic check with default settings
    $SCRIPT_NAME

    # Verbose output with all check details
    $SCRIPT_NAME --verbose

    # Check with custom thresholds
    $SCRIPT_NAME --thresholds '{"cpu_max":75,"memory_max":80}'

    # Check specific provider with debug logging
    $SCRIPT_NAME --provider claude --debug

DECISION LOGIC:
    1. Check token capacity (if enabled)
       - Verify session and weekly token limits
       - Apply safety margin to prevent over-utilization

    2. Check resource capacity (if enabled)
       - Verify CPU and memory availability
       - Ensure resources for new container

    3. Check operational status (if enabled)
       - Verify concurrent container limits
       - Check for operational issues

    Decision: All enabled checks must pass for "available" status

INTEGRATION:
    This script integrates with:
    - usage-monitor.sh: Token usage tracking
    - check-resource-capacity.sh: System resource monitoring
    - check-container-capacity.sh: Combined capacity checking
    - llm-orchestrator.sh: Autonomous task orchestration

SEE ALSO:
    - Feature #750: LLM availability checking and decision logic
    - Epic #263: Multi-LLM Task Orchestrator
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider)
                PROVIDER="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --thresholds)
                CUSTOM_THRESHOLDS="$2"
                shift 2
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
                echo ""
                usage
                exit 1
                ;;
        esac
    done
}

# Load and validate custom thresholds
load_thresholds() {
    if [ -n "$CUSTOM_THRESHOLDS" ]; then
        log_debug "Loading custom thresholds: $CUSTOM_THRESHOLDS"

        # Validate JSON
        if ! echo "$CUSTOM_THRESHOLDS" | jq empty 2>/dev/null; then
            log_error "Invalid JSON in --thresholds argument"
            exit 1
        fi

        # Override thresholds from JSON
        CPU_MAX_THRESHOLD=$(echo "$CUSTOM_THRESHOLDS" | jq -r '.cpu_max // '$CPU_MAX_THRESHOLD'')
        MEMORY_MAX_THRESHOLD=$(echo "$CUSTOM_THRESHOLDS" | jq -r '.memory_max // '$MEMORY_MAX_THRESHOLD'')
        SESSION_TOKEN_LIMIT=$(echo "$CUSTOM_THRESHOLDS" | jq -r '.session_token_limit // '$SESSION_TOKEN_LIMIT'')
        WEEKLY_TOKEN_LIMIT=$(echo "$CUSTOM_THRESHOLDS" | jq -r '.weekly_token_limit // '$WEEKLY_TOKEN_LIMIT'')
        TOKEN_SAFETY_MARGIN=$(echo "$CUSTOM_THRESHOLDS" | jq -r '.token_safety_margin // '$TOKEN_SAFETY_MARGIN'')
        MAX_CONCURRENT_CONTAINERS=$(echo "$CUSTOM_THRESHOLDS" | jq -r '.max_concurrent // '$MAX_CONCURRENT_CONTAINERS'')
    fi
}

# Check token capacity using usage-monitor.sh
check_token_capacity() {
    local usage_monitor="${SCRIPT_DIR}/usage-monitor.sh"

    log_debug "Checking token capacity..."

    # Check if usage monitor exists
    if [ ! -x "$usage_monitor" ]; then
        log_warn "usage-monitor.sh not found or not executable"
        echo '{
            "passed": true,
            "reason": "token monitoring unavailable - assuming available",
            "warning": "usage-monitor.sh not found"
        }'
        return 0
    fi

    # Get usage status
    local usage_json
    if ! usage_json=$("$usage_monitor" --format json 2>&1); then
        log_warn "Failed to get token usage status"
        echo '{
            "passed": true,
            "reason": "token check failed - assuming available",
            "warning": "usage-monitor.sh execution failed"
        }'
        return 0
    fi

    # Extract availability
    local session_available weekly_available
    session_available=$(echo "$usage_json" | jq -r '.session.available // true')
    weekly_available=$(echo "$usage_json" | jq -r '.weekly.available // true')

    # Extract usage percentages
    local session_pct weekly_pct
    session_pct=$(echo "$usage_json" | jq -r '.session.percentage_used // 0')
    weekly_pct=$(echo "$usage_json" | jq -r '.weekly.percentage_used // 0')

    # Calculate effective limits with safety margin
    local session_safe_limit weekly_safe_limit
    session_safe_limit=$((100 - TOKEN_SAFETY_MARGIN))
    weekly_safe_limit=$((100 - TOKEN_SAFETY_MARGIN))

    # Determine if capacity available (with safety margin)
    local passed=true
    local reason="Token capacity available"

    if [ "$session_available" != "true" ]; then
        passed=false
        reason="Session token limit exceeded"
    elif [ "$weekly_available" != "true" ]; then
        passed=false
        reason="Weekly token limit exceeded"
    elif [ "$session_pct" -ge "$session_safe_limit" ]; then
        passed=false
        reason="Session usage too high (${session_pct}% >= ${session_safe_limit}% with safety margin)"
    elif [ "$weekly_pct" -ge "$weekly_safe_limit" ]; then
        passed=false
        reason="Weekly usage too high (${weekly_pct}% >= ${weekly_safe_limit}% with safety margin)"
    else
        reason="Token capacity available (session: ${session_pct}%, weekly: ${weekly_pct}%)"
    fi

    # Build result JSON
    jq -n \
        --arg passed "$passed" \
        --arg reason "$reason" \
        --argjson session_pct "$session_pct" \
        --argjson weekly_pct "$weekly_pct" \
        --argjson session_safe_limit "$session_safe_limit" \
        --argjson weekly_safe_limit "$weekly_safe_limit" \
        --argjson usage_data "$usage_json" \
        '{
            passed: ($passed == "true"),
            reason: $reason,
            session_usage_pct: $session_pct,
            weekly_usage_pct: $weekly_pct,
            session_safe_limit: $session_safe_limit,
            weekly_safe_limit: $weekly_safe_limit,
            usage_data: $usage_data
        }'
}

# Check resource capacity using check-resource-capacity.sh
check_resource_capacity() {
    local resource_check="${SCRIPT_DIR}/check-resource-capacity.sh"

    log_debug "Checking resource capacity..."

    # Check if resource checker exists
    if [ ! -x "$resource_check" ]; then
        log_warn "check-resource-capacity.sh not found or not executable"
        echo '{
            "passed": true,
            "reason": "resource monitoring unavailable - assuming available",
            "warning": "check-resource-capacity.sh not found"
        }'
        return 0
    fi

    # Export thresholds for resource check script
    export CONTAINER_CPU_MAX_THRESHOLD="$CPU_MAX_THRESHOLD"
    export CONTAINER_MEMORY_MAX_THRESHOLD="$MEMORY_MAX_THRESHOLD"

    # Get resource status
    local resource_json
    if ! resource_json=$("$resource_check" 2>&1); then
        log_warn "Failed to check resource capacity"
        echo '{
            "passed": true,
            "reason": "resource check failed - assuming available",
            "warning": "check-resource-capacity.sh execution failed"
        }'
        return 0
    fi

    # Extract capacity status
    local has_capacity reason
    has_capacity=$(echo "$resource_json" | jq -r '.has_capacity // true')
    reason=$(echo "$resource_json" | jq -r '.reason // "unknown"')

    # Build result JSON
    jq -n \
        --arg passed "$has_capacity" \
        --arg reason "$reason" \
        --argjson resource_data "$resource_json" \
        '{
            passed: ($passed == "true"),
            reason: $reason,
            resource_data: $resource_data
        }'
}

# Check operational status (container count, system health)
check_operational_status() {
    log_debug "Checking operational status..."

    # Get running container count
    local container_count=0
    if command -v docker &>/dev/null; then
        container_count=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    fi

    # Check against limit
    local passed=true
    local reason="Operational status normal"

    if [ "$container_count" -ge "$MAX_CONCURRENT_CONTAINERS" ]; then
        passed=false
        reason="Too many concurrent containers (${container_count} >= ${MAX_CONCURRENT_CONTAINERS})"
    else
        reason="Operational status normal (${container_count} containers running)"
    fi

    # Build result JSON
    jq -n \
        --arg passed "$passed" \
        --arg reason "$reason" \
        --argjson container_count "$container_count" \
        --argjson max_concurrent "$MAX_CONCURRENT_CONTAINERS" \
        '{
            passed: ($passed == "true"),
            reason: $reason,
            container_count: $container_count,
            max_concurrent: $max_concurrent
        }'
}

# Perform all availability checks
check_availability() {
    log_debug "Performing availability checks for provider: $PROVIDER"

    # Initialize check results
    local token_check='{"passed": true, "reason": "check disabled"}'
    local resource_check='{"passed": true, "reason": "check disabled"}'
    local operational_check='{"passed": true, "reason": "check disabled"}'

    # Run enabled checks
    if [ "$TOKEN_CHECK_ENABLED" = "true" ]; then
        token_check=$(check_token_capacity)
    else
        log_debug "Token capacity check disabled"
    fi

    if [ "$RESOURCE_CHECK_ENABLED" = "true" ]; then
        resource_check=$(check_resource_capacity)
    else
        log_debug "Resource capacity check disabled"
    fi

    if [ "$OPERATIONAL_CHECK_ENABLED" = "true" ]; then
        operational_check=$(check_operational_status)
    else
        log_debug "Operational status check disabled"
    fi

    # Determine overall availability
    local token_passed resource_passed operational_passed
    token_passed=$(echo "$token_check" | jq -r '.passed // true')
    resource_passed=$(echo "$resource_check" | jq -r '.passed // true')
    operational_passed=$(echo "$operational_check" | jq -r '.passed // true')

    local available=false
    local reason=""
    local decision="skip"
    local failed_checks=()

    # Check each component
    if [ "$token_passed" != "true" ]; then
        failed_checks+=("token_capacity")
        reason=$(echo "$token_check" | jq -r '.reason')
    fi

    if [ "$resource_passed" != "true" ]; then
        failed_checks+=("resource_capacity")
        if [ -z "$reason" ]; then
            reason=$(echo "$resource_check" | jq -r '.reason')
        fi
    fi

    if [ "$operational_passed" != "true" ]; then
        failed_checks+=("operational_status")
        if [ -z "$reason" ]; then
            reason=$(echo "$operational_check" | jq -r '.reason')
        fi
    fi

    # Determine final status
    if [ "$token_passed" = "true" ] && [ "$resource_passed" = "true" ] && [ "$operational_passed" = "true" ]; then
        available=true
        decision="trigger"
        reason="All availability checks passed - ready to trigger work"
    else
        available=false
        decision="skip"
        if [ -z "$reason" ]; then
            reason="One or more availability checks failed"
        fi
    fi

    # Build failed_checks JSON array
    local failed_checks_json="[]"
    if [ "${#failed_checks[@]}" -gt 0 ]; then
        failed_checks_json="$(printf '%s\n' "${failed_checks[@]}" | jq -R . | jq -s .)"
    fi

    # Build output JSON
    if [ "$VERBOSE" = "true" ]; then
        # Verbose mode: include full check details
        jq -n \
            --arg available "$available" \
            --arg provider "$PROVIDER" \
            --arg reason "$reason" \
            --arg decision "$decision" \
            --argjson failed_checks "$failed_checks_json" \
            --argjson token_check "$token_check" \
            --argjson resource_check "$resource_check" \
            --argjson operational_check "$operational_check" \
            --argjson thresholds "$(jq -n \
                --argjson cpu_max "$CPU_MAX_THRESHOLD" \
                --argjson memory_max "$MEMORY_MAX_THRESHOLD" \
                --argjson session_limit "$SESSION_TOKEN_LIMIT" \
                --argjson weekly_limit "$WEEKLY_TOKEN_LIMIT" \
                --argjson token_margin "$TOKEN_SAFETY_MARGIN" \
                --argjson max_concurrent "$MAX_CONCURRENT_CONTAINERS" \
                '{
                    cpu_max_pct: $cpu_max,
                    memory_max_pct: $memory_max,
                    session_token_limit: $session_limit,
                    weekly_token_limit: $weekly_limit,
                    token_safety_margin_pct: $token_margin,
                    max_concurrent_containers: $max_concurrent
                }')" \
            '{
                available: ($available == "true"),
                provider: $provider,
                reason: $reason,
                decision: $decision,
                failed_checks: $failed_checks,
                checks: {
                    token_capacity: $token_check,
                    resource_capacity: $resource_check,
                    operational_status: $operational_check
                },
                thresholds: $thresholds,
                timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }'
    else
        # Compact mode: just essential info
        jq -n \
            --arg available "$available" \
            --arg provider "$PROVIDER" \
            --arg reason "$reason" \
            --arg decision "$decision" \
            --argjson failed_checks "$failed_checks_json" \
            --arg token_passed "$token_passed" \
            --arg resource_passed "$resource_passed" \
            --arg operational_passed "$operational_passed" \
            '{
                available: ($available == "true"),
                provider: $provider,
                reason: $reason,
                decision: $decision,
                failed_checks: $failed_checks,
                checks: {
                    token_capacity: { passed: ($token_passed == "true") },
                    resource_capacity: { passed: ($resource_passed == "true") },
                    operational_status: { passed: ($operational_passed == "true") }
                },
                timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }'
    fi
}

# Main function
main() {
    # Parse arguments
    parse_args "$@"

    # Validate provider
    if [ "$PROVIDER" != "claude" ]; then
        log_error "Unsupported provider: $PROVIDER"
        log_error "Currently only 'claude' is supported"
        exit 1
    fi

    # Check dependencies
    require_command jq

    # Load thresholds
    load_thresholds

    log_debug "Configuration loaded:"
    log_debug "  Provider: $PROVIDER"
    log_debug "  Token check: $TOKEN_CHECK_ENABLED"
    log_debug "  Resource check: $RESOURCE_CHECK_ENABLED"
    log_debug "  Operational check: $OPERATIONAL_CHECK_ENABLED"
    log_debug "  CPU threshold: ${CPU_MAX_THRESHOLD}%"
    log_debug "  Memory threshold: ${MEMORY_MAX_THRESHOLD}%"
    log_debug "  Token safety margin: ${TOKEN_SAFETY_MARGIN}%"
    log_debug "  Max concurrent: $MAX_CONCURRENT_CONTAINERS"

    # Perform availability check
    local result
    result=$(check_availability)

    # Output result
    echo "$result" | jq '.'

    # Exit with success (0) regardless of availability status
    # The availability status is in the JSON output
    exit 0
}

# Run main with all arguments
main "$@"
