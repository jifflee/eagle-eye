#!/bin/bash
set -euo pipefail
# container-logs.sh
# Query and filter container operation logs
# Part of Phase 9: Audit logging (Issue #142)
# size-ok: multi-filter log query tool with recent/issue/errors/container/tail modes
#
# Usage:
#   ./scripts/container-logs.sh --recent 10
#   ./scripts/container-logs.sh --issue 132
#   ./scripts/container-logs.sh --errors
#   ./scripts/container-logs.sh --container abc123
#   ./scripts/container-logs.sh --export json > debug.json

set -e

# Script metadata
SCRIPT_NAME="container-logs.sh"
VERSION="1.0.0"

# Log location
LOG_DIR="${HOME}/.claude-tastic/logs"
LOG_FILE="${LOG_DIR}/container-operations.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Query container operation logs

USAGE:
    $SCRIPT_NAME [OPTIONS]

FILTER OPTIONS:
    --recent <N>        Show last N log entries (default: 20)
    --issue <N>         Filter by issue number
    --container <ID>    Filter by container ID
    --event <TYPE>      Filter by event type (e.g., CONTAINER_START, CONTAINER_ERROR)
    --errors            Show only error/failed events
    --today             Show only today's events
    --since <TIME>      Show events since TIME (e.g., "1 hour ago", "2025-01-15")

OUTPUT OPTIONS:
    --export <FORMAT>   Export as FORMAT (json, csv)
    --no-color          Disable colored output
    --raw               Output raw log lines (no formatting)
    --stats             Show summary statistics only
    --json              Shorthand for --export json

EXAMPLES:
    # Show last 20 entries
    $SCRIPT_NAME --recent 20

    # Show all events for issue 132
    $SCRIPT_NAME --issue 132

    # Show errors only
    $SCRIPT_NAME --errors

    # Show today's activity with stats
    $SCRIPT_NAME --today --stats

    # Export to JSON for debugging
    $SCRIPT_NAME --export json > debug.json

    # Filter by container and event type
    $SCRIPT_NAME --container abc123 --event CONTAINER_PR

LOG FORMAT:
    timestamp|container_id|issue|event|details|outcome

LOG LOCATION:
    $LOG_FILE

EOF
}

# Check if log file exists
check_log_file() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "No log file found at $LOG_FILE" >&2
        echo "Container operations have not been logged yet." >&2
        exit 0
    fi
}

# Parse log line into components
parse_line() {
    local line="$1"
    IFS='|' read -r timestamp container_id issue event details outcome <<< "$line"
    echo "$timestamp" "$container_id" "$issue" "$event" "$details" "$outcome"
}

# Format a log line for display
format_line() {
    local line="$1"
    local no_color="$2"

    IFS='|' read -r timestamp container_id issue event details outcome <<< "$line"

    # Skip malformed lines
    if [ -z "$event" ]; then
        return
    fi

    # Color based on outcome
    local outcome_color="$GREEN"
    if [ "$outcome" = "failed" ] || [ "$outcome" = "error" ]; then
        outcome_color="$RED"
    elif [ "$outcome" = "warning" ]; then
        outcome_color="$YELLOW"
    fi

    # Color based on event type
    local event_color="$CYAN"
    case "$event" in
        CONTAINER_ERROR)
            event_color="$RED"
            ;;
        CONTAINER_START)
            event_color="$GREEN"
            ;;
        CONTAINER_STOP)
            event_color="$YELLOW"
            ;;
        CONTAINER_PR)
            event_color="$BLUE"
            ;;
    esac

    if [ "$no_color" = "true" ]; then
        printf "%-24s %-14s %-6s %-18s %-8s %s\n" \
            "$timestamp" "$container_id" "$issue" "$event" "$outcome" "$details"
    else
        printf "%-24s ${BLUE}%-14s${NC} %-6s ${event_color}%-18s${NC} ${outcome_color}%-8s${NC} %s\n" \
            "$timestamp" "$container_id" "$issue" "$event" "$outcome" "$details"
    fi
}

# Filter log by criteria
filter_logs() {
    local issue_filter="$1"
    local container_filter="$2"
    local event_filter="$3"
    local errors_only="$4"
    local since_filter="$5"

    local filter_cmd="cat"

    # Build filter pipeline
    if [ -n "$issue_filter" ]; then
        filter_cmd="$filter_cmd | awk -F'|' '\$3 == \"$issue_filter\"'"
    fi

    if [ -n "$container_filter" ]; then
        filter_cmd="$filter_cmd | awk -F'|' '\$2 ~ /$container_filter/'"
    fi

    if [ -n "$event_filter" ]; then
        filter_cmd="$filter_cmd | awk -F'|' '\$4 == \"$event_filter\"'"
    fi

    if [ "$errors_only" = "true" ]; then
        filter_cmd="$filter_cmd | awk -F'|' '\$6 == \"error\" || \$6 == \"failed\"'"
    fi

    if [ -n "$since_filter" ]; then
        # Convert since to timestamp for comparison
        local since_ts
        since_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$since_filter" "+%s" 2>/dev/null || \
                  date -d "$since_filter" "+%s" 2>/dev/null || echo "0")

        if [ "$since_ts" != "0" ]; then
            filter_cmd="$filter_cmd | awk -F'|' 'BEGIN{since=$since_ts} {
                # Parse timestamp (simplified - just compare strings for ISO format)
                if (\$1 >= \"$since_filter\") print
            }'"
        fi
    fi

    eval "$filter_cmd"
}

# Export logs to JSON
export_json() {
    echo "["
    local first=true
    while IFS='|' read -r timestamp container_id issue event details outcome; do
        if [ -z "$event" ]; then
            continue
        fi
        if [ "$first" = "true" ]; then
            first=false
        else
            echo ","
        fi
        # Escape quotes in details
        details=$(echo "$details" | sed 's/"/\\"/g')
        echo -n "  {\"timestamp\": \"$timestamp\", \"container_id\": \"$container_id\", \"issue\": \"$issue\", \"event\": \"$event\", \"details\": \"$details\", \"outcome\": \"$outcome\"}"
    done
    echo ""
    echo "]"
}

# Export logs to CSV
export_csv() {
    echo "timestamp,container_id,issue,event,details,outcome"
    while IFS='|' read -r timestamp container_id issue event details outcome; do
        if [ -z "$event" ]; then
            continue
        fi
        # Escape commas and quotes in details
        details=$(echo "$details" | sed 's/"/""/g')
        echo "\"$timestamp\",\"$container_id\",\"$issue\",\"$event\",\"$details\",\"$outcome\""
    done
}

# Show summary statistics
show_stats() {
    local input="$1"

    local total=0
    local starts=0
    local stops=0
    local errors=0
    local prs=0
    local unique_issues=""
    local unique_containers=""

    while IFS='|' read -r timestamp container_id issue event details outcome; do
        if [ -z "$event" ]; then
            continue
        fi
        ((total++))
        case "$event" in
            CONTAINER_START) ((starts++)) ;;
            CONTAINER_STOP) ((stops++)) ;;
            CONTAINER_ERROR) ((errors++)) ;;
            CONTAINER_PR) ((prs++)) ;;
        esac
        if [ "$outcome" = "error" ] || [ "$outcome" = "failed" ]; then
            ((errors++))
        fi
        unique_issues="$unique_issues $issue"
        unique_containers="$unique_containers $container_id"
    done <<< "$input"

    # Count unique values
    local issue_count
    issue_count=$(echo "$unique_issues" | tr ' ' '\n' | sort -u | grep -v '^$' | wc -l | tr -d ' ')
    local container_count
    container_count=$(echo "$unique_containers" | tr ' ' '\n' | sort -u | grep -v '^$' | wc -l | tr -d ' ')

    echo ""
    echo "=== Container Operations Statistics ==="
    echo ""
    printf "%-20s %s\n" "Total Events:" "$total"
    printf "%-20s %s\n" "Container Starts:" "$starts"
    printf "%-20s %s\n" "Container Stops:" "$stops"
    printf "%-20s %s\n" "PRs Created:" "$prs"
    printf "%-20s %s\n" "Errors/Failures:" "$errors"
    printf "%-20s %s\n" "Unique Issues:" "$issue_count"
    printf "%-20s %s\n" "Unique Containers:" "$container_count"
    echo ""
}

# Main function
main() {
    local recent=20
    local issue_filter=""
    local container_filter=""
    local event_filter=""
    local errors_only="false"
    local since_filter=""
    local today_only="false"
    local export_format=""
    local no_color="false"
    local raw_output="false"
    local show_stats_only="false"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --recent)
                recent="$2"
                shift 2
                ;;
            --issue)
                issue_filter="$2"
                shift 2
                ;;
            --container)
                container_filter="$2"
                shift 2
                ;;
            --event)
                event_filter="$2"
                shift 2
                ;;
            --errors)
                errors_only="true"
                shift
                ;;
            --today)
                today_only="true"
                since_filter=$(date -u '+%Y-%m-%dT00:00:00Z')
                shift
                ;;
            --since)
                since_filter="$2"
                shift 2
                ;;
            --export)
                export_format="$2"
                shift 2
                ;;
            --json)
                export_format="json"
                shift
                ;;
            --no-color)
                no_color="true"
                shift
                ;;
            --raw)
                raw_output="true"
                shift
                ;;
            --stats)
                show_stats_only="true"
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
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    check_log_file

    # Build the pipeline
    local logs
    logs=$(cat "$LOG_FILE")

    # Apply filters
    if [ -n "$issue_filter" ]; then
        logs=$(echo "$logs" | awk -F'|' -v issue="$issue_filter" '$3 == issue')
    fi

    if [ -n "$container_filter" ]; then
        logs=$(echo "$logs" | awk -F'|' -v container="$container_filter" '$2 ~ container')
    fi

    if [ -n "$event_filter" ]; then
        logs=$(echo "$logs" | awk -F'|' -v event="$event_filter" '$4 == event')
    fi

    if [ "$errors_only" = "true" ]; then
        logs=$(echo "$logs" | awk -F'|' '$6 == "error" || $6 == "failed"')
    fi

    if [ -n "$since_filter" ]; then
        logs=$(echo "$logs" | awk -F'|' -v since="$since_filter" '$1 >= since')
    fi

    # Apply recent limit
    logs=$(echo "$logs" | tail -n "$recent")

    # Handle empty results
    if [ -z "$logs" ]; then
        echo "No matching log entries found." >&2
        exit 0
    fi

    # Stats only mode
    if [ "$show_stats_only" = "true" ]; then
        show_stats "$logs"
        exit 0
    fi

    # Export modes
    case "$export_format" in
        json)
            echo "$logs" | export_json
            exit 0
            ;;
        csv)
            echo "$logs" | export_csv
            exit 0
            ;;
    esac

    # Raw output
    if [ "$raw_output" = "true" ]; then
        echo "$logs"
        exit 0
    fi

    # Formatted output
    echo ""
    printf "%-24s %-14s %-6s %-18s %-8s %s\n" "TIMESTAMP" "CONTAINER" "ISSUE" "EVENT" "OUTCOME" "DETAILS"
    printf "%-24s %-14s %-6s %-18s %-8s %s\n" "─────────" "─────────" "─────" "─────" "───────" "───────"

    while IFS= read -r line; do
        format_line "$line" "$no_color"
    done <<< "$logs"

    echo ""
}

# Run main with all arguments
main "$@"
