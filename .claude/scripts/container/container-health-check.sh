#!/bin/bash
set -euo pipefail
# container-health-check.sh
# Health check script for container auto-recovery (Issue #493)
#
# Features:
#   - Detects containers running without progress (stuck)
#   - Detects containers with non-zero exit codes (failed)
#   - Outputs JSON for n8n integration
#   - Supports configurable thresholds
#
# Usage:
#   ./scripts/container-health-check.sh                    # Check all containers
#   ./scripts/container-health-check.sh --issue 107        # Check specific issue
#   ./scripts/container-health-check.sh --stuck-threshold 1800  # 30 min (seconds)
#   ./scripts/container-health-check.sh --json             # JSON output
#   ./scripts/container-health-check.sh --daemon           # Run as daemon (poll mode)
#
# Exit codes:
#   0 = All containers healthy
#   1 = Issues detected (stuck or failed containers)
#   2 = Error (no Docker, etc.)

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Script metadata
SCRIPT_NAME="container-health-check.sh"
VERSION="1.0.0"

# Default thresholds
DEFAULT_STUCK_THRESHOLD=1800  # 30 minutes in seconds
DEFAULT_HEARTBEAT_THRESHOLD=300  # 5 minutes without log output
DEFAULT_POLL_INTERVAL=300  # 5 minutes for daemon mode

# Webhook URL for n8n alerting (optional)
RECOVERY_WEBHOOK_URL="${CONTAINER_RECOVERY_WEBHOOK:-}"

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Container health check for auto-recovery

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    --issue <N>               Check specific issue container only
    --stuck-threshold <sec>   Seconds before container considered stuck (default: $DEFAULT_STUCK_THRESHOLD)
    --heartbeat-threshold <sec>  Seconds without log output = stuck (default: $DEFAULT_HEARTBEAT_THRESHOLD)
    --json                    Output in JSON format
    --quiet                   Only output if issues found
    --daemon                  Run in daemon mode (poll continuously)
    --poll-interval <sec>     Polling interval for daemon mode (default: $DEFAULT_POLL_INTERVAL)
    --auto-recover            Automatically trigger recovery for stuck/failed containers
    --webhook <url>           Webhook URL to notify on issues (or set CONTAINER_RECOVERY_WEBHOOK)
    --debug                   Enable debug logging

EXAMPLES:
    # Check all containers
    $SCRIPT_NAME

    # Check with JSON output
    $SCRIPT_NAME --json

    # Run as daemon with auto-recovery
    $SCRIPT_NAME --daemon --auto-recover

    # Check specific container with custom threshold
    $SCRIPT_NAME --issue 107 --stuck-threshold 900

ENVIRONMENT:
    CONTAINER_RECOVERY_WEBHOOK    Webhook URL for recovery notifications

EOF
}

# Check Docker availability
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        return 2
    fi
    if ! docker info &> /dev/null 2>&1; then
        log_error "Docker daemon is not running"
        return 2
    fi
    return 0
}

# Get last activity timestamp from container logs
get_last_activity_timestamp() {
    local container="$1"

    # Get the timestamp of the last log entry
    local last_log
    last_log=$(docker logs --tail 1 --timestamps "$container" 2>/dev/null | head -1)

    if [ -z "$last_log" ]; then
        echo "0"
        return
    fi

    # Extract timestamp (format: 2024-01-15T10:30:45.123456789Z)
    local timestamp
    timestamp=$(echo "$last_log" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)

    if [ -z "$timestamp" ]; then
        echo "0"
        return
    fi

    # Convert to epoch (macOS compatible)
    local epoch
    epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" "+%s" 2>/dev/null || \
            date -d "$timestamp" "+%s" 2>/dev/null || echo "0")

    echo "$epoch"
}

# Get heartbeat timestamp from container (Issue #508)
# Returns epoch timestamp of last heartbeat, or 0 if not available
get_heartbeat_timestamp() {
    local container="$1"

    # Try to read heartbeat file from container
    local heartbeat_json
    heartbeat_json=$(docker exec "$container" cat /tmp/heartbeat 2>/dev/null || echo "")

    if [ -z "$heartbeat_json" ]; then
        echo "0"
        return
    fi

    local timestamp
    timestamp=$(echo "$heartbeat_json" | jq -r '.timestamp // empty' 2>/dev/null)

    if [ -z "$timestamp" ]; then
        echo "0"
        return
    fi

    # Convert to epoch
    local epoch
    epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%s" 2>/dev/null || \
            date -d "$timestamp" "+%s" 2>/dev/null || echo "0")

    echo "$epoch"
}

# Get heartbeat phase from container
get_heartbeat_phase() {
    local container="$1"

    local heartbeat_json
    heartbeat_json=$(docker exec "$container" cat /tmp/heartbeat 2>/dev/null || echo "")

    if [ -z "$heartbeat_json" ]; then
        echo "unknown"
        return
    fi

    echo "$heartbeat_json" | jq -r '.phase // "unknown"' 2>/dev/null
}

# Get container start time as epoch
get_container_start_time() {
    local container="$1"

    local started_at
    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null)

    if [ -z "$started_at" ]; then
        echo "0"
        return
    fi

    # Parse ISO timestamp
    local timestamp="${started_at:0:19}"
    local epoch
    epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" "+%s" 2>/dev/null || \
            date -d "$timestamp" "+%s" 2>/dev/null || echo "0")

    echo "$epoch"
}

# Check if a single container is healthy
check_container_health() {
    local container="$1"
    local stuck_threshold="$2"
    local heartbeat_threshold="$3"

    local now
    now=$(date +%s)

    local status
    status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")

    local result_status="healthy"
    local result_reason=""
    local result_action=""

    case "$status" in
        running)
            # Check for stuck using heartbeat first (Issue #508), fall back to logs
            local last_activity
            local heartbeat_time
            local current_phase="unknown"

            # Try heartbeat first (more reliable)
            heartbeat_time=$(get_heartbeat_timestamp "$container")

            if [ "$heartbeat_time" -gt 0 ]; then
                last_activity=$heartbeat_time
                current_phase=$(get_heartbeat_phase "$container")
                log_debug "Using heartbeat timestamp for $container (phase: $current_phase)"
            else
                # Fall back to log-based detection
                last_activity=$(get_last_activity_timestamp "$container")
                log_debug "No heartbeat, using log timestamp for $container"
            fi

            local start_time
            start_time=$(get_container_start_time "$container")

            # Use start time if no activity detected yet
            if [ "$last_activity" -eq 0 ] && [ "$start_time" -gt 0 ]; then
                last_activity=$start_time
            fi

            local seconds_since_activity=$((now - last_activity))
            local seconds_running=$((now - start_time))

            # Check heartbeat threshold (no recent activity)
            if [ "$seconds_since_activity" -gt "$heartbeat_threshold" ]; then
                result_status="stuck"
                if [ "$heartbeat_time" -gt 0 ]; then
                    result_reason="No heartbeat for ${seconds_since_activity}s (phase: $current_phase, threshold: ${heartbeat_threshold}s)"
                else
                    result_reason="No log output for ${seconds_since_activity}s (threshold: ${heartbeat_threshold}s)"
                fi
                result_action="kill_and_retry"
            fi

            # Check overall running time threshold
            if [ "$seconds_running" -gt "$stuck_threshold" ]; then
                result_status="stuck"
                result_reason="Running for ${seconds_running}s (phase: $current_phase, threshold: ${stuck_threshold}s)"
                result_action="kill_and_retry"
            fi
            ;;
        exited)
            local exit_code
            exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "1")

            if [ "$exit_code" != "0" ]; then
                result_status="failed"
                result_reason="Container exited with code $exit_code"
                result_action="preserve_logs_and_notify"
            else
                result_status="completed"
                result_reason="Container exited successfully"
                result_action="none"
            fi
            ;;
        created|paused|restarting|removing|dead)
            result_status="unhealthy"
            result_reason="Container in unexpected state: $status"
            result_action="investigate"
            ;;
        *)
            result_status="unknown"
            result_reason="Could not determine container state"
            result_action="investigate"
            ;;
    esac

    # Extract issue number from container name
    local issue_num
    issue_num="${container#${CONTAINER_PREFIX}-}"

    # Get heartbeat info for JSON output (Issue #508)
    local heartbeat_available="false"
    local heartbeat_age="null"
    local heartbeat_phase='""'

    if [ "$status" = "running" ]; then
        local hb_time
        hb_time=$(get_heartbeat_timestamp "$container")
        if [ "$hb_time" -gt 0 ]; then
            heartbeat_available="true"
            heartbeat_age=$((now - hb_time))
            heartbeat_phase=$(get_heartbeat_phase "$container")
        fi
    fi

    # Build JSON result
    cat << EOF
{
  "container": "$container",
  "issue": "$issue_num",
  "docker_status": "$status",
  "health_status": "$result_status",
  "reason": "$result_reason",
  "recommended_action": "$result_action",
  "heartbeat": {
    "available": $heartbeat_available,
    "age_seconds": $heartbeat_age,
    "phase": "$heartbeat_phase"
  },
  "checked_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

# Check all containers and aggregate results
check_all_containers() {
    local issue_filter="$1"
    local stuck_threshold="$2"
    local heartbeat_threshold="$3"
    local json_output="$4"
    local quiet="$5"

    local filter_arg=""
    if [ -n "$issue_filter" ]; then
        filter_arg="-$issue_filter"
    fi

    # Get all containers with our prefix
    local containers
    containers=$(docker ps -a --filter "name=${CONTAINER_PREFIX}${filter_arg}" --format '{{.Names}}' 2>/dev/null)

    if [ -z "$containers" ]; then
        if [ "$json_output" = "true" ]; then
            echo '{"containers":[],"summary":{"total":0,"healthy":0,"stuck":0,"failed":0,"completed":0},"overall_status":"healthy"}'
        elif [ "$quiet" != "true" ]; then
            log_info "No containers found"
        fi
        return 0
    fi

    local results=()
    local total=0
    local healthy=0
    local stuck=0
    local failed=0
    local completed=0
    local issues_found=0

    while IFS= read -r container; do
        [ -z "$container" ] && continue

        local health_json
        health_json=$(check_container_health "$container" "$stuck_threshold" "$heartbeat_threshold")

        results+=("$health_json")
        ((total++))

        local status
        status=$(echo "$health_json" | jq -r '.health_status')

        case "$status" in
            healthy) ((healthy++)) ;;
            stuck) ((stuck++)); ((issues_found++)) ;;
            failed) ((failed++)); ((issues_found++)) ;;
            completed) ((completed++)) ;;
            *) ((issues_found++)) ;;
        esac
    done <<< "$containers"

    # Determine overall status
    local overall_status="healthy"
    if [ "$issues_found" -gt 0 ]; then
        overall_status="issues_detected"
    fi

    if [ "$json_output" = "true" ]; then
        # Build JSON array
        local containers_json
        containers_json=$(printf '%s\n' "${results[@]}" | jq -s '.')

        cat << EOF
{
  "containers": $containers_json,
  "summary": {
    "total": $total,
    "healthy": $healthy,
    "stuck": $stuck,
    "failed": $failed,
    "completed": $completed
  },
  "overall_status": "$overall_status",
  "checked_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    else
        if [ "$quiet" = "true" ] && [ "$issues_found" -eq 0 ]; then
            return 0
        fi

        echo ""
        echo -e "${BLUE}=== Container Health Check ===${NC}"
        echo ""
        printf "%-30s %-12s %-10s %s\n" "CONTAINER" "STATUS" "DOCKER" "REASON"
        printf "%-30s %-12s %-10s %s\n" "---------" "------" "------" "------"

        for result in "${results[@]}"; do
            local container status docker_status reason
            container=$(echo "$result" | jq -r '.container')
            status=$(echo "$result" | jq -r '.health_status')
            docker_status=$(echo "$result" | jq -r '.docker_status')
            reason=$(echo "$result" | jq -r '.reason')

            local status_color
            case "$status" in
                healthy) status_color="${GREEN}healthy${NC}" ;;
                stuck) status_color="${YELLOW}stuck${NC}" ;;
                failed) status_color="${RED}failed${NC}" ;;
                completed) status_color="${GREEN}completed${NC}" ;;
                *) status_color="${RED}$status${NC}" ;;
            esac

            printf "%-30s %-12b %-10s %s\n" "$container" "$status_color" "$docker_status" "${reason:0:40}"
        done

        echo ""
        echo "Summary: $total total, $healthy healthy, $stuck stuck, $failed failed, $completed completed"
        echo ""
    fi

    if [ "$issues_found" -gt 0 ]; then
        return 1
    fi
    return 0
}

# Trigger recovery for a container
trigger_recovery() {
    local container="$1"
    local action="$2"
    local reason="$3"

    log_info "Triggering recovery for $container (action: $action)"

    local issue_num
    issue_num="${container#${CONTAINER_PREFIX}-}"

    case "$action" in
        kill_and_retry)
            log_warn "Killing stuck container: $container"
            docker kill "$container" 2>/dev/null || true

            # Send webhook notification
            if [ -n "$RECOVERY_WEBHOOK_URL" ]; then
                send_recovery_webhook "$issue_num" "stuck" "$reason" "killed"
            fi
            ;;
        preserve_logs_and_notify)
            log_warn "Container failed: $container"

            # Preserve logs
            local log_file="${FRAMEWORK_LOG_DIR}/containers/${container}_$(date '+%Y%m%d_%H%M%S').log"
            mkdir -p "$(dirname "$log_file")"
            docker logs "$container" > "$log_file" 2>&1 || true
            log_info "Logs preserved: $log_file"

            # Send webhook notification
            if [ -n "$RECOVERY_WEBHOOK_URL" ]; then
                send_recovery_webhook "$issue_num" "failed" "$reason" "logs_preserved"
            fi
            ;;
        investigate)
            log_warn "Container needs investigation: $container"
            if [ -n "$RECOVERY_WEBHOOK_URL" ]; then
                send_recovery_webhook "$issue_num" "unknown" "$reason" "investigate"
            fi
            ;;
    esac
}

# Send webhook to n8n for recovery notification
send_recovery_webhook() {
    local issue="$1"
    local status="$2"
    local reason="$3"
    local action_taken="$4"

    if [ -z "$RECOVERY_WEBHOOK_URL" ]; then
        log_debug "No webhook URL configured, skipping notification"
        return 0
    fi

    local payload
    payload=$(cat << EOF
{
  "event": "container_recovery",
  "issue": "$issue",
  "container": "${CONTAINER_PREFIX}-${issue}",
  "status": "$status",
  "reason": "$reason",
  "action_taken": "$action_taken",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

    log_debug "Sending webhook to: $RECOVERY_WEBHOOK_URL"

    curl -s -X POST "$RECOVERY_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || {
        log_warn "Failed to send recovery webhook"
    }
}

# Run in daemon mode
run_daemon() {
    local poll_interval="$1"
    local stuck_threshold="$2"
    local heartbeat_threshold="$3"
    local auto_recover="$4"

    log_info "Starting health check daemon (poll interval: ${poll_interval}s)"
    log_info "Stuck threshold: ${stuck_threshold}s, Heartbeat threshold: ${heartbeat_threshold}s"

    while true; do
        log_debug "Running health check..."

        local result
        result=$(check_all_containers "" "$stuck_threshold" "$heartbeat_threshold" "true" "false")

        local overall_status
        overall_status=$(echo "$result" | jq -r '.overall_status')

        if [ "$overall_status" = "issues_detected" ] && [ "$auto_recover" = "true" ]; then
            # Process each container with issues
            echo "$result" | jq -r '.containers[] | select(.health_status == "stuck" or .health_status == "failed") | @base64' | while read -r encoded; do
                local container_data
                container_data=$(echo "$encoded" | base64 -d)

                local container action reason
                container=$(echo "$container_data" | jq -r '.container')
                action=$(echo "$container_data" | jq -r '.recommended_action')
                reason=$(echo "$container_data" | jq -r '.reason')

                trigger_recovery "$container" "$action" "$reason"
            done
        fi

        sleep "$poll_interval"
    done
}

# Main function
main() {
    local issue=""
    local stuck_threshold="$DEFAULT_STUCK_THRESHOLD"
    local heartbeat_threshold="$DEFAULT_HEARTBEAT_THRESHOLD"
    local poll_interval="$DEFAULT_POLL_INTERVAL"
    local json_output="false"
    local quiet="false"
    local daemon_mode="false"
    local auto_recover="false"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --issue)
                issue="$2"
                shift 2
                ;;
            --stuck-threshold)
                stuck_threshold="$2"
                shift 2
                ;;
            --heartbeat-threshold)
                heartbeat_threshold="$2"
                shift 2
                ;;
            --poll-interval)
                poll_interval="$2"
                shift 2
                ;;
            --json)
                json_output="true"
                shift
                ;;
            --quiet)
                quiet="true"
                shift
                ;;
            --daemon)
                daemon_mode="true"
                shift
                ;;
            --auto-recover)
                auto_recover="true"
                shift
                ;;
            --webhook)
                RECOVERY_WEBHOOK_URL="$2"
                shift 2
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

    # Check Docker
    check_docker || exit 2

    if [ "$daemon_mode" = "true" ]; then
        run_daemon "$poll_interval" "$stuck_threshold" "$heartbeat_threshold" "$auto_recover"
    else
        check_all_containers "$issue" "$stuck_threshold" "$heartbeat_threshold" "$json_output" "$quiet"
    fi
}

# Run main with all arguments
main "$@"
