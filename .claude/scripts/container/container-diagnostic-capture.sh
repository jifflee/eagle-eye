#!/bin/bash
set -euo pipefail
# container-diagnostic-capture.sh
# Captures diagnostic logs and analyzes container failures
# Feature #610: Container startup failure with diagnostic log analysis
#
# Features:
#   - Detects premature container exits (< 30 seconds runtime)
#   - Captures last N lines of diagnostic logs
#   - Parses common error patterns
#   - Auto-restart capability for transient failures
#   - Integrates with n8n diagnostics workflow (#609)
#
# Usage:
#   ./scripts/container-diagnostic-capture.sh --container <name>
#   ./scripts/container-diagnostic-capture.sh --issue <N>
#   ./scripts/container-diagnostic-capture.sh --container <name> --auto-restart
#   ./scripts/container-diagnostic-capture.sh --container <name> --log-lines 100

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Script metadata
SCRIPT_NAME="container-diagnostic-capture.sh"
VERSION="1.0.0"

# Defaults
DEFAULT_LOG_LINES=100
PREMATURE_EXIT_THRESHOLD=30  # seconds
DEFAULT_OUTPUT_DIR="${FRAMEWORK_LOG_DIR}/diagnostics"

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Diagnostic log capture and analysis for container failures

USAGE:
    $SCRIPT_NAME --container <name> [OPTIONS]
    $SCRIPT_NAME --issue <N> [OPTIONS]

OPTIONS:
    --container <name>      Container name to analyze
    --issue <N>             Issue number (constructs container name)
    --log-lines <N>         Number of log lines to capture (default: $DEFAULT_LOG_LINES)
    --auto-restart          Attempt auto-restart for transient failures
    --output-dir <path>     Directory for diagnostic logs (default: $DEFAULT_OUTPUT_DIR)
    --json                  Output results in JSON format
    --webhook <url>         Send diagnostics to n8n webhook (for issue #609)
    --debug                 Enable debug logging

EXAMPLES:
    # Capture diagnostics for failed container
    $SCRIPT_NAME --container claude-tastic-issue-571

    # Capture with auto-restart
    $SCRIPT_NAME --issue 571 --auto-restart

    # Capture and send to n8n workflow
    $SCRIPT_NAME --issue 571 --webhook https://n8n.example.com/webhook/diagnostics

    # Capture last 200 lines
    $SCRIPT_NAME --container claude-tastic-issue-571 --log-lines 200

ENVIRONMENT:
    CONTAINER_DIAGNOSTICS_WEBHOOK    Default webhook URL for diagnostics

EXIT CODES:
    0 = Container healthy or successfully analyzed
    1 = Container failure detected
    2 = Error in script execution
EOF
}

# Get container runtime in seconds
get_container_runtime() {
    local container="$1"

    local started_at finished_at
    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null)
    finished_at=$(docker inspect --format '{{.State.FinishedAt}}' "$container" 2>/dev/null)

    if [ -z "$started_at" ] || [ "$started_at" = "0001-01-01T00:00:00Z" ]; then
        echo "0"
        return
    fi

    # Parse timestamps
    local start_epoch finish_epoch
    start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${started_at:0:19}" "+%s" 2>/dev/null || echo "0")

    if [ -z "$finished_at" ] || [ "$finished_at" = "0001-01-01T00:00:00Z" ]; then
        # Still running
        finish_epoch=$(date +%s)
    else
        finish_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${finished_at:0:19}" "+%s" 2>/dev/null || echo "0")
    fi

    if [ "$start_epoch" -eq 0 ] || [ "$finish_epoch" -eq 0 ]; then
        echo "0"
        return
    fi

    echo $((finish_epoch - start_epoch))
}

# Detect if exit was premature
is_premature_exit() {
    local container="$1"
    local threshold="${2:-$PREMATURE_EXIT_THRESHOLD}"

    local status
    status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")

    if [ "$status" != "exited" ]; then
        return 1
    fi

    local runtime
    runtime=$(get_container_runtime "$container")

    if [ "$runtime" -lt "$threshold" ]; then
        return 0
    fi

    return 1
}

# Capture container logs
capture_logs() {
    local container="$1"
    local lines="$2"
    local output_file="$3"

    log_info "Capturing last $lines lines of logs from $container"

    docker logs --tail "$lines" "$container" > "$output_file" 2>&1 || {
        log_error "Failed to capture logs from $container"
        return 1
    }

    log_info "Logs saved to: $output_file"
    return 0
}

# Parse error patterns from logs
parse_error_patterns() {
    local log_file="$1"

    local errors=()

    # Common error patterns
    local patterns=(
        "ERROR"
        "Error:"
        "error:"
        "FATAL"
        "Fatal:"
        "Exception"
        "Traceback"
        "panic:"
        "authentication failed"
        "token.*invalid"
        "token.*expired"
        "permission denied"
        "No such file"
        "cannot find"
        "Connection refused"
        "timeout"
        "ECONNREFUSED"
        "ETIMEDOUT"
        "segmentation fault"
        "core dumped"
    )

    for pattern in "${patterns[@]}"; do
        if grep -i -q "$pattern" "$log_file" 2>/dev/null; then
            local matches
            matches=$(grep -i -n "$pattern" "$log_file" | head -3)
            if [ -n "$matches" ]; then
                errors+=("$pattern: $matches")
            fi
        fi
    done

    if [ ${#errors[@]} -eq 0 ]; then
        echo "no_errors_detected"
    else
        printf '%s\n' "${errors[@]}"
    fi
}

# Categorize failure type based on error patterns
categorize_failure() {
    local log_file="$1"

    # Check for authentication issues
    if grep -i -q -E "(authentication failed|token.*invalid|token.*expired|oauth.*error)" "$log_file" 2>/dev/null; then
        echo "auth_failure"
        return
    fi

    # Check for permission issues
    if grep -i -q -E "(permission denied|EACCES)" "$log_file" 2>/dev/null; then
        echo "permission_error"
        return
    fi

    # Check for network issues
    if grep -i -q -E "(Connection refused|ECONNREFUSED|timeout|ETIMEDOUT|network unreachable)" "$log_file" 2>/dev/null; then
        echo "network_error"
        return
    fi

    # Check for missing dependencies
    if grep -i -q -E "(cannot find|No such file|command not found|module not found)" "$log_file" 2>/dev/null; then
        echo "dependency_error"
        return
    fi

    # Check for OOM or resource issues
    if grep -i -q -E "(out of memory|OOM|cannot allocate)" "$log_file" 2>/dev/null; then
        echo "resource_error"
        return
    fi

    # Check for segfault or crashes
    if grep -i -q -E "(segmentation fault|core dumped|panic)" "$log_file" 2>/dev/null; then
        echo "crash"
        return
    fi

    # Check if container exited cleanly but prematurely (no visible errors)
    if ! grep -i -q -E "(error|exception|fatal|fail)" "$log_file" 2>/dev/null; then
        echo "silent_exit"
        return
    fi

    echo "unknown_error"
}

# Determine if failure is transient (can be retried)
is_transient_failure() {
    local category="$1"

    case "$category" in
        network_error|timeout|silent_exit)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Attempt to restart container
restart_container() {
    local container="$1"

    log_info "Attempting to restart container: $container"

    if docker start "$container" &> /dev/null; then
        log_info "Container $container restarted successfully"
        return 0
    else
        log_error "Failed to restart container $container"
        return 1
    fi
}

# Send diagnostics to webhook (n8n integration for #609)
send_diagnostics_webhook() {
    local webhook_url="$1"
    local issue="$2"
    local container="$3"
    local exit_code="$4"
    local runtime="$5"
    local category="$6"
    local log_file="$7"

    if [ -z "$webhook_url" ]; then
        log_debug "No webhook URL provided, skipping webhook"
        return 0
    fi

    log_info "Sending diagnostics to webhook: $webhook_url"

    # Extract last 50 lines of logs for webhook
    local log_excerpt=""
    if [ -f "$log_file" ]; then
        log_excerpt=$(tail -50 "$log_file" | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')
    fi

    local payload
    payload=$(cat << EOF
{
  "event": "container_diagnostic",
  "issue": "$issue",
  "container": "$container",
  "exit_code": $exit_code,
  "runtime_seconds": $runtime,
  "failure_category": "$category",
  "log_excerpt": "$log_excerpt",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

    curl -s -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || {
        log_warn "Failed to send diagnostics webhook"
        return 1
    }

    log_info "Diagnostics sent to webhook successfully"
    return 0
}

# Generate diagnostic summary
generate_diagnostic_summary() {
    local container="$1"
    local exit_code="$2"
    local runtime="$3"
    local category="$4"
    local log_file="$5"
    local json_output="$6"

    local issue_num
    issue_num="${container#${CONTAINER_PREFIX}-}"

    local error_lines
    error_lines=$(parse_error_patterns "$log_file")

    local is_transient="false"
    if is_transient_failure "$category"; then
        is_transient="true"
    fi

    if [ "$json_output" = "true" ]; then
        # JSON output
        local errors_json="[]"
        if [ "$error_lines" != "no_errors_detected" ]; then
            errors_json=$(echo "$error_lines" | jq -R . | jq -s .)
        fi

        cat << EOF
{
  "container": "$container",
  "issue": "$issue_num",
  "exit_code": $exit_code,
  "runtime_seconds": $runtime,
  "premature_exit": $([ "$runtime" -lt "$PREMATURE_EXIT_THRESHOLD" ] && echo "true" || echo "false"),
  "failure_category": "$category",
  "is_transient": $is_transient,
  "errors": $errors_json,
  "log_file": "$log_file",
  "analyzed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    else
        # Human-readable output
        echo ""
        echo -e "${BLUE}=== Container Diagnostic Summary ===${NC}"
        echo ""
        echo "Container:        $container"
        echo "Issue:            #$issue_num"
        echo "Exit Code:        $exit_code"
        echo "Runtime:          ${runtime}s"
        echo "Premature Exit:   $([ "$runtime" -lt "$PREMATURE_EXIT_THRESHOLD" ] && echo "YES" || echo "NO")"
        echo "Failure Category: $category"
        echo "Transient:        $([ "$is_transient" = "true" ] && echo "YES (can retry)" || echo "NO")"
        echo ""
        echo "Error Patterns:"
        if [ "$error_lines" = "no_errors_detected" ]; then
            echo "  No obvious errors detected in logs"
        else
            echo "$error_lines" | sed 's/^/  /'
        fi
        echo ""
        echo "Full logs: $log_file"
        echo ""
    fi
}

# Main diagnostic workflow
run_diagnostics() {
    local container="$1"
    local log_lines="$2"
    local output_dir="$3"
    local auto_restart="$4"
    local json_output="$5"
    local webhook_url="$6"

    # Verify container exists
    if ! docker inspect "$container" &> /dev/null; then
        log_error "Container $container not found"
        return 2
    fi

    # Get container state
    local status exit_code runtime
    status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
    exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "0")
    runtime=$(get_container_runtime "$container")

    log_info "Container $container: status=$status, exit_code=$exit_code, runtime=${runtime}s"

    # Check if container is still running
    if [ "$status" = "running" ]; then
        # Check for premature issues (running but might be stuck)
        if [ "$runtime" -lt "$PREMATURE_EXIT_THRESHOLD" ]; then
            log_warn "Container is running but only for ${runtime}s (< ${PREMATURE_EXIT_THRESHOLD}s)"
            log_warn "May be stuck or initializing - monitoring recommended"
        else
            log_info "Container is running normally (${runtime}s)"
        fi

        # Capture logs anyway for analysis
        mkdir -p "$output_dir"
        local log_file="${output_dir}/${container}_running_$(date '+%Y%m%d_%H%M%S').log"
        capture_logs "$container" "$log_lines" "$log_file"

        return 0
    fi

    # Container has exited - analyze
    log_info "Container has exited, analyzing..."

    # Create output directory
    mkdir -p "$output_dir"

    # Capture logs
    local log_file="${output_dir}/${container}_$(date '+%Y%m%d_%H%M%S').log"
    capture_logs "$container" "$log_lines" "$log_file" || return 2

    # Categorize failure
    local category
    category=$(categorize_failure "$log_file")
    log_info "Failure category: $category"

    # Generate summary
    generate_diagnostic_summary "$container" "$exit_code" "$runtime" "$category" "$log_file" "$json_output"

    # Send to webhook if configured
    local issue_num
    issue_num="${container#${CONTAINER_PREFIX}-}"
    send_diagnostics_webhook "$webhook_url" "$issue_num" "$container" "$exit_code" "$runtime" "$category" "$log_file"

    # Auto-restart logic
    if [ "$auto_restart" = "true" ]; then
        if is_premature_exit "$container" && [ "$exit_code" -eq 0 ]; then
            log_warn "Premature exit detected (${runtime}s, exit code 0)"

            if is_transient_failure "$category"; then
                log_info "Transient failure detected, attempting restart..."
                restart_container "$container"
            else
                log_warn "Non-transient failure ($category), skipping restart"
                log_warn "Manual intervention may be required"
            fi
        elif [ "$exit_code" -ne 0 ]; then
            log_error "Container exited with non-zero code ($exit_code), not attempting restart"
        fi
    fi

    # Return exit code based on container health
    if [ "$exit_code" -eq 0 ] && [ "$runtime" -ge "$PREMATURE_EXIT_THRESHOLD" ]; then
        return 0
    else
        return 1
    fi
}

# Main function
main() {
    local container=""
    local issue=""
    local log_lines="$DEFAULT_LOG_LINES"
    local output_dir="$DEFAULT_OUTPUT_DIR"
    local auto_restart="false"
    local json_output="false"
    local webhook_url="${CONTAINER_DIAGNOSTICS_WEBHOOK:-}"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --container)
                container="$2"
                shift 2
                ;;
            --issue)
                issue="$2"
                container="${CONTAINER_PREFIX}-${issue}"
                shift 2
                ;;
            --log-lines)
                log_lines="$2"
                shift 2
                ;;
            --output-dir)
                output_dir="$2"
                shift 2
                ;;
            --auto-restart)
                auto_restart="true"
                shift
                ;;
            --json)
                json_output="true"
                shift
                ;;
            --webhook)
                webhook_url="$2"
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
                exit 2
                ;;
        esac
    done

    # Validate inputs
    if [ -z "$container" ]; then
        log_error "Container name or issue number required"
        usage
        exit 2
    fi

    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 2
    fi

    if ! docker info &> /dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 2
    fi

    # Run diagnostics
    run_diagnostics "$container" "$log_lines" "$output_dir" "$auto_restart" "$json_output" "$webhook_url"
}

# Run main with all arguments
main "$@"
