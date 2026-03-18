#!/bin/bash
set -euo pipefail
# container-metrics.sh
# Metrics collection and reporting for container operations
# Part of Issue #510: Structured logging and metrics collection
#
# Provides utilities to extract and report metrics from container logs.
# Can be used both inside containers and on the host.
#
# Usage:
#   # From inside container
#   ./container-metrics.sh --show
#
#   # From host (via docker cp or logs)
#   docker cp <container>:/tmp/metrics.json ./metrics.json
#   ./container-metrics.sh --file ./metrics.json
#
#   # Query specific log events
#   ./container-metrics.sh --query-log /tmp/container.log --event git_commit

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities if available
if [ -f "${SCRIPT_DIR}/../lib/common.sh" ]; then
    source "${SCRIPT_DIR}/../lib/common.sh"
fi

# Default paths
METRICS_FILE="${METRICS_FILE:-/tmp/metrics.json}"
CONTAINER_LOG="${CONTAINER_LOG:-/tmp/container.log}"
PROGRESS_LOG="${PROGRESS_LOG:-/tmp/progress.jsonl}"

# ============================================================
# Display Functions
# ============================================================

# Show metrics in human-readable format
show_metrics() {
    local file="${1:-$METRICS_FILE}"

    if [ ! -f "$file" ]; then
        echo "Error: Metrics file not found: $file" >&2
        exit 1
    fi

    echo "==================================================================="
    echo "Container Metrics Report"
    echo "==================================================================="
    echo ""

    # Parse and display metrics
    local started_at
    local completed_at
    local total_duration_ms
    local files_written
    local commits
    local errors

    started_at=$(jq -r '.started_at // "unknown"' "$file")
    completed_at=$(jq -r '.completed_at // "unknown"' "$file")
    total_duration_ms=$(jq -r '.total_duration_ms // 0' "$file")
    files_written=$(jq -r '.files_written // 0' "$file")
    commits=$(jq -r '.commits // 0' "$file")
    errors=$(jq -r '.errors // 0' "$file")

    echo "Session Information:"
    echo "  Started:  $started_at"
    echo "  Completed: $completed_at"
    echo "  Duration: $(format_duration "$total_duration_ms")"
    echo ""

    echo "Activity Summary:"
    echo "  Files Written: $files_written"
    echo "  Git Commits:   $commits"
    echo "  Errors:        $errors"
    echo ""

    # Show phase breakdown
    echo "Phase Breakdown:"
    local phases
    phases=$(jq -r '.phases | keys[]' "$file" 2>/dev/null || echo "")

    if [ -z "$phases" ]; then
        echo "  (no phases tracked)"
    else
        for phase in $phases; do
            local phase_duration
            local phase_status
            phase_duration=$(jq -r ".phases.\"$phase\".duration_ms // 0" "$file")
            phase_status=$(jq -r ".phases.\"$phase\".status // \"unknown\"" "$file")

            # Format status with color if terminal supports it
            local status_display="$phase_status"
            if [ -t 1 ]; then
                case "$phase_status" in
                    complete)
                        status_display="\033[0;32m${phase_status}\033[0m"
                        ;;
                    error)
                        status_display="\033[0;31m${phase_status}\033[0m"
                        ;;
                    in_progress)
                        status_display="\033[0;33m${phase_status}\033[0m"
                        ;;
                esac
            fi

            printf "  %-15s  %-20s  %s\n" "$phase" "$(format_duration "$phase_duration")" "$(echo -e "$status_display")"
        done
    fi

    echo ""
    echo "==================================================================="
}

# Format milliseconds to human-readable duration
format_duration() {
    local ms="$1"
    local seconds=$((ms / 1000))
    local minutes=$((seconds / 60))
    local hours=$((minutes / 60))

    if [ "$hours" -gt 0 ]; then
        echo "${hours}h $((minutes % 60))m $((seconds % 60))s"
    elif [ "$minutes" -gt 0 ]; then
        echo "${minutes}m $((seconds % 60))s"
    else
        echo "${seconds}s"
    fi
}

# ============================================================
# Log Query Functions
# ============================================================

# Query log file for specific events
query_log() {
    local log_file="$1"
    local event_filter="${2:-}"
    local level_filter="${3:-}"
    local format="${4:-human}"

    if [ ! -f "$log_file" ]; then
        echo "Error: Log file not found: $log_file" >&2
        exit 1
    fi

    # Build jq filter
    local jq_filter="."

    if [ -n "$event_filter" ]; then
        jq_filter="$jq_filter | select(.event == \"$event_filter\")"
    fi

    if [ -n "$level_filter" ]; then
        jq_filter="$jq_filter | select(.level == \"$level_filter\")"
    fi

    # Apply filter and format output
    case "$format" in
        json)
            jq "$jq_filter" "$log_file"
            ;;
        human)
            jq -r "$jq_filter | \"\(.ts) [\(.level)] \(.event): \(.message)\"" "$log_file"
            ;;
        csv)
            echo "timestamp,level,event,message"
            jq -r "$jq_filter | [\(.ts), .level, .event, .message] | @csv" "$log_file"
            ;;
        *)
            echo "Error: Unknown format: $format" >&2
            exit 1
            ;;
    esac
}

# Extract metrics from log file
extract_metrics_from_log() {
    local log_file="${1:-$CONTAINER_LOG}"

    if [ ! -f "$log_file" ]; then
        echo "Error: Log file not found: $log_file" >&2
        exit 1
    fi

    # Count events by type
    local file_writes
    local commits
    local errors
    local phases

    file_writes=$(jq -s '[.[] | select(.event == "file_write")] | length' "$log_file")
    commits=$(jq -s '[.[] | select(.event == "git_commit")] | length' "$log_file")
    errors=$(jq -s '[.[] | select(.level == "ERROR")] | length' "$log_file")

    # Extract unique phases
    phases=$(jq -s '[.[] | select(.event == "phase_start" or .event == "phase_complete") | .context.phase] | unique' "$log_file")

    # Build summary
    jq -n \
        --arg file_writes "$file_writes" \
        --arg commits "$commits" \
        --arg errors "$errors" \
        --argjson phases "$phases" \
        '{
            files_written: ($file_writes | tonumber),
            commits: ($commits | tonumber),
            errors: ($errors | tonumber),
            phases: $phases,
            source: "extracted_from_log"
        }'
}

# ============================================================
# Export Functions
# ============================================================

# Export logs for external analysis
export_logs() {
    local output_dir="${1:-.}"
    local container_name="${2:-}"

    mkdir -p "$output_dir"

    # Copy metrics file
    if [ -f "$METRICS_FILE" ]; then
        cp "$METRICS_FILE" "$output_dir/metrics.json"
        echo "Exported: $output_dir/metrics.json"
    fi

    # Copy structured log
    if [ -f "$CONTAINER_LOG" ]; then
        cp "$CONTAINER_LOG" "$output_dir/container.log"
        echo "Exported: $output_dir/container.log"
    fi

    # Copy progress log
    if [ -f "$PROGRESS_LOG" ]; then
        cp "$PROGRESS_LOG" "$output_dir/progress.jsonl"
        echo "Exported: $output_dir/progress.jsonl"
    fi

    echo ""
    echo "Logs exported to: $output_dir"
}

# ============================================================
# Dashboard Integration
# ============================================================

# Generate dashboard-ready metrics
generate_dashboard_metrics() {
    local metrics_file="${1:-$METRICS_FILE}"

    if [ ! -f "$metrics_file" ]; then
        echo "Error: Metrics file not found: $metrics_file" >&2
        exit 1
    fi

    # Enhance metrics with dashboard-specific fields
    jq '. + {
        dashboard_version: "1.0",
        success_rate: (if .errors == 0 then 1.0 else 0.0 end),
        productivity_score: (.commits + .files_written),
        timestamp: now | todateiso8601
    }' "$metrics_file"
}

# ============================================================
# Main
# ============================================================

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Container metrics collection and reporting tool.

OPTIONS:
    --show [FILE]           Show metrics in human-readable format
                            (default: $METRICS_FILE)

    --json [FILE]           Output metrics as JSON
                            (default: $METRICS_FILE)

    --query-log FILE        Query log file for events
      --event EVENT         Filter by event type
      --level LEVEL         Filter by log level (INFO, WARN, ERROR)
      --format FORMAT       Output format (human, json, csv)

    --extract-from-log FILE Extract metrics from log file

    --export DIR            Export all logs to directory

    --dashboard [FILE]      Generate dashboard-ready metrics
                            (default: $METRICS_FILE)

    --help                  Show this help message

EXAMPLES:
    # Show metrics
    $0 --show

    # Query for all errors
    $0 --query-log /tmp/container.log --level ERROR

    # Query for git commits
    $0 --query-log /tmp/container.log --event git_commit --format json

    # Export logs
    $0 --export ./container-logs

    # Generate dashboard metrics
    $0 --dashboard | jq .

EOF
}

# Parse arguments
ACTION=""
FILE_ARG=""
EVENT_FILTER=""
LEVEL_FILTER=""
FORMAT="human"
OUTPUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --show)
            ACTION="show"
            shift
            [ $# -gt 0 ] && [ "${1:0:1}" != "-" ] && FILE_ARG="$1" && shift
            ;;
        --json)
            ACTION="json"
            shift
            [ $# -gt 0 ] && [ "${1:0:1}" != "-" ] && FILE_ARG="$1" && shift
            ;;
        --query-log)
            ACTION="query"
            shift
            [ $# -gt 0 ] && FILE_ARG="$1" && shift
            ;;
        --event)
            shift
            [ $# -gt 0 ] && EVENT_FILTER="$1" && shift
            ;;
        --level)
            shift
            [ $# -gt 0 ] && LEVEL_FILTER="$1" && shift
            ;;
        --format)
            shift
            [ $# -gt 0 ] && FORMAT="$1" && shift
            ;;
        --extract-from-log)
            ACTION="extract"
            shift
            [ $# -gt 0 ] && FILE_ARG="$1" && shift
            ;;
        --export)
            ACTION="export"
            shift
            [ $# -gt 0 ] && OUTPUT_DIR="$1" && shift
            ;;
        --dashboard)
            ACTION="dashboard"
            shift
            [ $# -gt 0 ] && [ "${1:0:1}" != "-" ] && FILE_ARG="$1" && shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Execute action
case "$ACTION" in
    show)
        show_metrics "${FILE_ARG:-$METRICS_FILE}"
        ;;
    json)
        cat "${FILE_ARG:-$METRICS_FILE}"
        ;;
    query)
        query_log "${FILE_ARG:-$CONTAINER_LOG}" "$EVENT_FILTER" "$LEVEL_FILTER" "$FORMAT"
        ;;
    extract)
        extract_metrics_from_log "${FILE_ARG:-$CONTAINER_LOG}"
        ;;
    export)
        export_logs "${OUTPUT_DIR:-.}"
        ;;
    dashboard)
        generate_dashboard_metrics "${FILE_ARG:-$METRICS_FILE}"
        ;;
    "")
        # Default: show metrics if file exists, otherwise show help
        if [ -f "$METRICS_FILE" ]; then
            show_metrics "$METRICS_FILE"
        else
            usage
            exit 1
        fi
        ;;
    *)
        echo "Error: Unknown action: $ACTION" >&2
        exit 1
        ;;
esac
