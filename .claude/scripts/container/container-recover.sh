#!/bin/bash
set -euo pipefail
# container-recover.sh
# Recovery wrapper for container execution with retry logic (Issue #493)
#
# Features:
#   - Wraps container launch with configurable retry logic
#   - Handles stuck containers (kill and retry)
#   - Handles failed containers (preserve logs, notify, optionally retry)
#   - Integrates with n8n for alerting via webhooks
#
# Usage:
#   ./scripts/container-recover.sh --issue 107 --repo owner/repo
#   ./scripts/container-recover.sh --issue 107 --repo owner/repo --max-retries 2
#   ./scripts/container-recover.sh --issue 107 --repo owner/repo --no-retry
#
# This script wraps container-launch.sh with recovery capabilities.

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Script metadata
SCRIPT_NAME="container-recover.sh"
VERSION="1.0.0"

# Default configuration
DEFAULT_MAX_RETRIES=1
DEFAULT_RETRY_DELAY=30  # seconds between retries
DEFAULT_TIMEOUT=1800    # 30 minutes
DEFAULT_STUCK_THRESHOLD=1800  # 30 minutes before considered stuck

# Webhook URL for n8n alerting (optional)
RECOVERY_WEBHOOK_URL="${CONTAINER_RECOVERY_WEBHOOK:-}"
LOG_DIR="${HOME}/.claude-tastic/logs/recovery"

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Container recovery wrapper with retry logic

USAGE:
    $SCRIPT_NAME --issue <N> --repo <owner/repo> [OPTIONS]

REQUIRED:
    --issue <N>             Issue number to work on
    --repo <owner/repo>     Repository (e.g., jifflee/claude-tastic)

OPTIONS:
    --max-retries <N>       Maximum retry attempts (default: $DEFAULT_MAX_RETRIES)
    --retry-delay <sec>     Delay between retries (default: $DEFAULT_RETRY_DELAY)
    --timeout <sec>         Container timeout (default: $DEFAULT_TIMEOUT)
    --stuck-threshold <sec> Seconds before container considered stuck (default: $DEFAULT_STUCK_THRESHOLD)
    --no-retry              Disable retry on failure
    --webhook <url>         Webhook URL for notifications (or set CONTAINER_RECOVERY_WEBHOOK)
    --branch <branch>       Target branch (default: auto-detected from repo's default branch)
    --image <image>         Docker image to use
    --debug                 Enable debug logging
    --dry-run               Show what would be done without executing

PASSTHROUGH OPTIONS:
    Additional options are passed directly to container-launch.sh

EXAMPLES:
    # Launch with default retry (1 retry on failure)
    $SCRIPT_NAME --issue 107 --repo owner/repo

    # Launch with 2 retries
    $SCRIPT_NAME --issue 107 --repo owner/repo --max-retries 2

    # Launch without retry
    $SCRIPT_NAME --issue 107 --repo owner/repo --no-retry

    # Launch with webhook notification
    $SCRIPT_NAME --issue 107 --repo owner/repo --webhook https://n8n.example.com/webhook/recovery

ENVIRONMENT:
    CONTAINER_RECOVERY_WEBHOOK    Default webhook URL for recovery notifications

EXIT CODES:
    0 = Container completed successfully
    1 = Container failed after all retries
    2 = Configuration/setup error

EOF
}

# Ensure log directory exists
ensure_log_dir() {
    mkdir -p "$LOG_DIR"
}

# Generate log file name for attempt
get_attempt_log_file() {
    local issue="$1"
    local attempt="$2"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    echo "$LOG_DIR/issue-${issue}_attempt-${attempt}_${timestamp}.log"
}

# Send webhook notification to n8n
send_webhook() {
    local event_type="$1"
    local issue="$2"
    local attempt="$3"
    local max_retries="$4"
    local status="$5"
    local details="$6"

    if [ -z "$RECOVERY_WEBHOOK_URL" ]; then
        log_debug "No webhook URL configured, skipping notification"
        return 0
    fi

    local payload
    payload=$(cat << EOF
{
  "event": "$event_type",
  "issue": $issue,
  "container": "${CONTAINER_PREFIX}-${issue}",
  "attempt": $attempt,
  "max_retries": $max_retries,
  "status": "$status",
  "details": "$details",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

    log_debug "Sending webhook: $event_type for issue #$issue"

    curl -s -X POST "$RECOVERY_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || {
        log_warn "Failed to send webhook notification"
    }
}

# Preserve container logs before cleanup
preserve_logs() {
    local container="$1"
    local log_file="$2"

    log_info "Preserving logs to: $log_file"

    {
        echo "=== Container Log Dump ==="
        echo "Container: $container"
        echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "=== Docker Inspect ==="
        docker inspect "$container" 2>/dev/null || echo "Could not inspect container"
        echo ""
        echo "=== Container Logs ==="
        docker logs "$container" 2>&1 || echo "Could not retrieve logs"
    } > "$log_file" 2>&1

    return 0
}

# Check if container is stuck
check_if_stuck() {
    local container="$1"
    local stuck_threshold="$2"

    # Get last log timestamp
    local last_log
    last_log=$(docker logs --tail 1 --timestamps "$container" 2>/dev/null | head -1)

    if [ -z "$last_log" ]; then
        return 1  # No logs, might be stuck
    fi

    local timestamp
    timestamp=$(echo "$last_log" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)

    if [ -z "$timestamp" ]; then
        return 1
    fi

    local now
    now=$(date +%s)
    local last_epoch
    last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" "+%s" 2>/dev/null || echo "0")

    local seconds_since=$((now - last_epoch))

    if [ "$seconds_since" -gt "$stuck_threshold" ]; then
        return 0  # Stuck
    fi

    return 1  # Not stuck
}

# Wait for container completion with stuck detection
wait_for_container() {
    local container="$1"
    local timeout="$2"
    local stuck_threshold="$3"

    local start_time
    start_time=$(date +%s)

    while true; do
        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))

        # Check timeout
        if [ "$elapsed" -ge "$timeout" ]; then
            log_warn "Container timed out after ${elapsed}s"
            return 124  # Standard timeout exit code
        fi

        # Check container status
        local status
        status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "removed")

        case "$status" in
            running)
                # Check if stuck
                if check_if_stuck "$container" "$stuck_threshold"; then
                    log_warn "Container appears stuck (no activity for ${stuck_threshold}s)"
                    return 125  # Custom code for stuck
                fi
                ;;
            exited)
                local exit_code
                exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "1")
                return "$exit_code"
                ;;
            removed|*)
                # Container was removed or in unexpected state
                return 1
                ;;
        esac

        sleep 30  # Check every 30 seconds
    done
}

# Launch container with recovery
launch_with_recovery() {
    local issue="$1"
    local repo="$2"
    local branch="$3"
    local image="$4"
    local max_retries="$5"
    local retry_delay="$6"
    local timeout="$7"
    local stuck_threshold="$8"
    local dry_run="$9"
    shift 9
    local passthrough_args=("$@")

    local container_name="${CONTAINER_PREFIX}-${issue}"
    local attempt=0
    local success=false

    ensure_log_dir

    log_info "Starting container with recovery for issue #$issue"
    log_info "Max retries: $max_retries, Timeout: ${timeout}s, Stuck threshold: ${stuck_threshold}s"

    while [ $attempt -le "$max_retries" ] && [ "$success" = "false" ]; do
        ((attempt++))

        if [ $attempt -gt 1 ]; then
            log_info "Retry attempt $attempt of $((max_retries + 1))"
            send_webhook "container_retry" "$issue" "$attempt" "$max_retries" "retrying" "Retry attempt $attempt"
            sleep "$retry_delay"
        fi

        local log_file
        log_file=$(get_attempt_log_file "$issue" "$attempt")

        log_info "Attempt $attempt: Launching container (log: $log_file)"

        if [ "$dry_run" = "true" ]; then
            log_info "[DRY-RUN] Would launch container for issue #$issue"
            log_info "[DRY-RUN] Command: $SCRIPT_DIR/container-launch.sh --issue $issue --repo $repo --branch $branch --sprint-work ${passthrough_args[*]}"
            success=true
            continue
        fi

        # Kill any existing container
        if docker ps -q --filter "name=^${container_name}$" | grep -q .; then
            log_warn "Killing existing container: $container_name"
            docker kill "$container_name" 2>/dev/null || true
            docker rm "$container_name" 2>/dev/null || true
            sleep 2
        fi

        # Build launch command
        # Only include --branch if explicitly specified; otherwise container-launch.sh detects it
        local launch_args=(
            "--issue" "$issue"
            "--repo" "$repo"
        )
        if [ -n "$branch" ]; then
            launch_args+=("--branch" "$branch")
        fi
        launch_args+=(
            "--sprint-work"
            "--sync"  # Run synchronously so we can monitor
            "--timeout" "$timeout"
        )

        if [ -n "$image" ]; then
            launch_args+=("--image" "$image")
        fi

        # Add passthrough args
        launch_args+=("${passthrough_args[@]}")

        # Launch container
        local exit_code=0
        "$SCRIPT_DIR/container-launch.sh" "${launch_args[@]}" > "$log_file" 2>&1 || exit_code=$?

        log_info "Container exited with code: $exit_code"

        case $exit_code in
            0)
                log_info "Container completed successfully"
                send_webhook "container_success" "$issue" "$attempt" "$max_retries" "success" "Container completed successfully"
                success=true
                ;;
            124)
                log_warn "Container timed out"
                preserve_logs "$container_name" "${log_file}.timeout"
                send_webhook "container_timeout" "$issue" "$attempt" "$max_retries" "timeout" "Container timed out after ${timeout}s"
                ;;
            125)
                log_warn "Container detected as stuck"
                preserve_logs "$container_name" "${log_file}.stuck"
                docker kill "$container_name" 2>/dev/null || true
                send_webhook "container_stuck" "$issue" "$attempt" "$max_retries" "stuck" "Container had no activity for ${stuck_threshold}s"
                ;;
            *)
                log_error "Container failed with exit code $exit_code"
                preserve_logs "$container_name" "${log_file}.failed"
                send_webhook "container_failed" "$issue" "$attempt" "$max_retries" "failed" "Exit code: $exit_code"
                ;;
        esac

        # Cleanup container if still exists
        docker rm "$container_name" 2>/dev/null || true
    done

    if [ "$success" = "true" ]; then
        log_info "Issue #$issue completed successfully"
        return 0
    else
        log_error "Issue #$issue failed after $attempt attempt(s)"
        send_webhook "container_exhausted" "$issue" "$attempt" "$max_retries" "exhausted" "All retry attempts failed"
        return 1
    fi
}

# Main function
main() {
    local issue=""
    local repo=""
    local branch=""  # Auto-detected from repo's default branch if not specified
    local image=""
    local max_retries="$DEFAULT_MAX_RETRIES"
    local retry_delay="$DEFAULT_RETRY_DELAY"
    local timeout="$DEFAULT_TIMEOUT"
    local stuck_threshold="$DEFAULT_STUCK_THRESHOLD"
    local dry_run="false"
    local passthrough_args=()

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --issue)
                issue="$2"
                shift 2
                ;;
            --repo)
                repo="$2"
                shift 2
                ;;
            --branch)
                branch="$2"
                shift 2
                ;;
            --image)
                image="$2"
                shift 2
                ;;
            --max-retries)
                max_retries="$2"
                shift 2
                ;;
            --retry-delay)
                retry_delay="$2"
                shift 2
                ;;
            --timeout)
                timeout="$2"
                shift 2
                ;;
            --stuck-threshold)
                stuck_threshold="$2"
                shift 2
                ;;
            --no-retry)
                max_retries=0
                shift
                ;;
            --webhook)
                RECOVERY_WEBHOOK_URL="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="true"
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
                # Pass unknown args to container-launch.sh
                passthrough_args+=("$1")
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$issue" ]; then
        log_error "--issue is required"
        usage
        exit 2
    fi

    if [ -z "$repo" ]; then
        log_error "--repo is required"
        usage
        exit 2
    fi

    # Launch with recovery
    launch_with_recovery \
        "$issue" \
        "$repo" \
        "$branch" \
        "$image" \
        "$max_retries" \
        "$retry_delay" \
        "$timeout" \
        "$stuck_threshold" \
        "$dry_run" \
        "${passthrough_args[@]}"
}

# Run main with all arguments
main "$@"
