#!/bin/bash
set -euo pipefail
# container-metrics-persist.sh
# Persist container metrics and logs to host storage
# Part of Issue #592: Persistent container observability
#
# This script extracts observability data from containers and stores it
# persistently on the host for historical analysis and n8n integration.
#
# Storage Location: $FRAMEWORK_DIR/metrics/ (default: ~/.claude-agent/metrics/)
#
# Usage:
#   ./scripts/container-metrics-persist.sh <issue_number>
#   ./scripts/container-metrics-persist.sh --all
#   ./scripts/container-metrics-persist.sh --query [--json]
#
# Exit codes:
#   0 = Success
#   1 = Container not found or error

set -e

# Get script directory and source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    source "$SCRIPT_DIR/lib/common.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Configuration
METRICS_DIR="${METRICS_DIR:-${FRAMEWORK_DIR}/metrics}"
METRICS_DB="$METRICS_DIR/container-metrics.jsonl"
LOGS_DIR="$METRICS_DIR/logs"

# Ensure directories exist
mkdir -p "$METRICS_DIR" "$LOGS_DIR"

# Usage
usage() {
    cat << EOF
container-metrics-persist.sh - Persist container observability data

USAGE:
    $0 <issue_number>     Persist metrics for specific issue
    $0 --all              Persist metrics for all containers
    $0 --query [options]  Query stored metrics

QUERY OPTIONS:
    --json                Output as JSON
    --issue <N>           Filter by issue number
    --status <status>     Filter by status (success/error)
    --since <hours>       Only show last N hours
    --limit <N>           Limit results (default: 20)

EXAMPLES:
    $0 590                          # Persist metrics for issue 590
    $0 --all                        # Persist all container metrics
    $0 --query --json               # Query all metrics as JSON
    $0 --query --issue 590          # Query metrics for issue 590
    $0 --query --status error       # Query failed containers
    $0 --query --since 24           # Query last 24 hours

STORAGE:
    Metrics DB: $METRICS_DB
    Logs Dir:   $LOGS_DIR
EOF
}

# Extract metrics from a container
extract_metrics() {
    local container="$1"
    local issue="${container#${CONTAINER_PREFIX}-}"

    log_info "Extracting metrics from $container..."

    # Get container state
    local state exit_code created_at
    state=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
    exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "-1")
    created_at=$(docker inspect --format '{{.Created}}' "$container" 2>/dev/null || echo "")

    # Try to get metrics.json from container
    local metrics_json="{}"
    if [ "$state" = "running" ]; then
        metrics_json=$(docker exec "$container" cat /tmp/metrics.json 2>/dev/null || echo "{}")
    else
        # For stopped containers, try docker cp
        local tmp_file=$(mktemp)
        if docker cp "$container:/tmp/metrics.json" "$tmp_file" 2>/dev/null; then
            metrics_json=$(cat "$tmp_file")
        fi
        rm -f "$tmp_file"
    fi

    # Try to get sprint result
    local sprint_result="{}"
    if [ "$state" = "running" ]; then
        sprint_result=$(docker exec "$container" cat /tmp/sprint-result.json 2>/dev/null || echo "{}")
    else
        local tmp_file=$(mktemp)
        if docker cp "$container:/tmp/sprint-result.json" "$tmp_file" 2>/dev/null; then
            sprint_result=$(cat "$tmp_file")
        fi
        rm -f "$tmp_file"
    fi

    # Extract key fields from sprint result
    local pr_number pr_url ci_status workflow_status
    pr_number=$(echo "$sprint_result" | jq -r '.pr_number // 0' 2>/dev/null || echo "0")
    pr_url=$(echo "$sprint_result" | jq -r '.pr_url // ""' 2>/dev/null || echo "")
    ci_status=$(echo "$sprint_result" | jq -r '.ci_status // "unknown"' 2>/dev/null || echo "unknown")
    workflow_status=$(echo "$sprint_result" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

    # Extract phase timings from metrics
    local phases_json
    phases_json=$(echo "$metrics_json" | jq '.phases // {}' 2>/dev/null || echo "{}")

    local total_duration_ms
    total_duration_ms=$(echo "$metrics_json" | jq '.total_duration_ms // 0' 2>/dev/null || echo "0")

    local files_written commits errors
    files_written=$(echo "$metrics_json" | jq '.files_written // 0' 2>/dev/null || echo "0")
    commits=$(echo "$metrics_json" | jq '.commits // 0' 2>/dev/null || echo "0")
    errors=$(echo "$metrics_json" | jq '.errors // 0' 2>/dev/null || echo "0")

    # Build combined record
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local record
    record=$(jq -n \
        --arg ts "$timestamp" \
        --arg issue "$issue" \
        --arg container "$container" \
        --arg state "$state" \
        --arg exit_code "$exit_code" \
        --arg created_at "$created_at" \
        --arg workflow_status "$workflow_status" \
        --arg pr_number "$pr_number" \
        --arg pr_url "$pr_url" \
        --arg ci_status "$ci_status" \
        --argjson phases "$phases_json" \
        --arg total_duration_ms "$total_duration_ms" \
        --arg files_written "$files_written" \
        --arg commits "$commits" \
        --arg errors "$errors" \
        '{
            persisted_at: $ts,
            issue: ($issue | tonumber),
            container: $container,
            state: $state,
            exit_code: ($exit_code | tonumber),
            created_at: $created_at,
            workflow_status: $workflow_status,
            pr_number: (if $pr_number == "" then 0 else ($pr_number | tonumber) end),
            pr_url: $pr_url,
            ci_status: $ci_status,
            phases: $phases,
            total_duration_ms: ($total_duration_ms | tonumber),
            files_written: ($files_written | tonumber),
            commits: ($commits | tonumber),
            errors: ($errors | tonumber)
        }')

    echo "$record"
}

# Save metrics to database
save_metrics() {
    local record="$1"
    local issue
    issue=$(echo "$record" | jq -r '.issue')

    # Append to JSONL database
    echo "$record" >> "$METRICS_DB"
    log_info "Metrics saved for issue #$issue"

    # Also save individual JSON file
    local issue_file="$METRICS_DIR/issue-${issue}.json"
    echo "$record" > "$issue_file"
}

# Save container logs
save_logs() {
    local container="$1"
    local issue="${container#${CONTAINER_PREFIX}-}"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')

    local log_file="$LOGS_DIR/${container}_${timestamp}.log"

    log_info "Saving logs for $container..."

    if docker logs "$container" > "$log_file" 2>&1; then
        log_info "Logs saved: $log_file"

        # Also try to save structured log
        local structured_log="$LOGS_DIR/${container}_${timestamp}_structured.jsonl"
        if docker cp "$container:/tmp/container.log" "$structured_log" 2>/dev/null; then
            log_info "Structured log saved: $structured_log"
        fi

        return 0
    else
        log_warn "Could not save logs for $container"
        return 1
    fi
}

# Persist metrics for a single issue
persist_issue() {
    local issue="$1"
    local container="${CONTAINER_PREFIX}-${issue}"

    # Check if container exists
    if ! docker inspect "$container" &>/dev/null; then
        log_error "Container not found: $container"
        return 1
    fi

    # Extract and save metrics
    local record
    record=$(extract_metrics "$container")
    save_metrics "$record"

    # Save logs
    save_logs "$container"

    # Output the record
    echo "$record"
}

# Persist metrics for all containers
persist_all() {
    log_info "Persisting metrics for all containers..."

    local containers
    containers=$(docker ps -a --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null)

    if [ -z "$containers" ]; then
        log_info "No containers found"
        return 0
    fi

    local count=0
    while IFS= read -r container; do
        local record
        record=$(extract_metrics "$container")
        save_metrics "$record"
        save_logs "$container"
        ((count++))
    done <<< "$containers"

    log_info "Persisted metrics for $count container(s)"
}

# Query stored metrics
query_metrics() {
    local json_output="false"
    local filter_issue=""
    local filter_status=""
    local since_hours=""
    local limit="20"

    # Parse query options
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json_output="true"; shift ;;
            --issue) filter_issue="$2"; shift 2 ;;
            --status) filter_status="$2"; shift 2 ;;
            --since) since_hours="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Check if database exists
    if [ ! -f "$METRICS_DB" ]; then
        if [ "$json_output" = "true" ]; then
            echo '{"records": [], "total": 0}'
        else
            log_info "No metrics found. Run '$0 --all' to persist container metrics."
        fi
        return 0
    fi

    # Build jq filter
    local jq_filter="."

    if [ -n "$filter_issue" ]; then
        jq_filter="$jq_filter | select(.issue == $filter_issue)"
    fi

    if [ -n "$filter_status" ]; then
        jq_filter="$jq_filter | select(.workflow_status == \"$filter_status\")"
    fi

    if [ -n "$since_hours" ]; then
        local since_ts
        since_ts=$(date -u -v-${since_hours}H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                   date -u -d "$since_hours hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
        if [ -n "$since_ts" ]; then
            jq_filter="$jq_filter | select(.persisted_at >= \"$since_ts\")"
        fi
    fi

    # Get filtered and sorted records
    local records_json
    records_json=$(jq -s "[ .[] | $jq_filter ] | sort_by(.persisted_at) | reverse | .[0:$limit]" "$METRICS_DB" 2>/dev/null || echo "[]")

    local total
    total=$(jq -s "[ .[] | $jq_filter ] | length" "$METRICS_DB" 2>/dev/null || echo "0")

    if [ "$json_output" = "true" ]; then
        # JSON output
        jq -n --argjson records "$records_json" --argjson total "$total" \
            '{records: $records, total: $total, showing: ($records | length)}'
    else
        # Human-readable table
        echo ""
        printf "%-8s %-12s %-10s %-8s %-10s %-8s %s\n" \
            "ISSUE" "STATUS" "DURATION" "FILES" "PR" "CI" "PERSISTED"
        printf "%-8s %-12s %-10s %-8s %-10s %-8s %s\n" \
            "─────" "──────" "────────" "─────" "──" "──" "─────────"

        echo "$records_json" | jq -c '.[]' 2>/dev/null | while IFS= read -r record; do
            local issue status duration files pr ci persisted
            issue=$(echo "$record" | jq -r '.issue')
            status=$(echo "$record" | jq -r '.workflow_status')
            duration=$(echo "$record" | jq -r '.total_duration_ms')
            files=$(echo "$record" | jq -r '.files_written')
            pr=$(echo "$record" | jq -r '.pr_number')
            ci=$(echo "$record" | jq -r '.ci_status')
            persisted=$(echo "$record" | jq -r '.persisted_at' | cut -d'T' -f1)

            # Format duration
            local duration_str
            if [ "$duration" != "0" ] && [ "$duration" != "null" ] && [ -n "$duration" ]; then
                duration_str="$((duration / 1000))s"
            else
                duration_str="-"
            fi

            # Format PR
            local pr_str
            if [ "$pr" != "0" ] && [ "$pr" != "null" ]; then
                pr_str="#$pr"
            else
                pr_str="-"
            fi

            printf "%-8s %-12s %-10s %-8s %-10s %-8s %s\n" \
                "#$issue" "$status" "$duration_str" "$files" "$pr_str" "$ci" "$persisted"
        done

        echo ""
        echo "Total records: $total (showing up to $limit)"
    fi
}

# Get summary statistics
get_summary() {
    local json_output="${1:-false}"

    if [ ! -f "$METRICS_DB" ]; then
        if [ "$json_output" = "true" ]; then
            echo '{"total": 0, "success": 0, "error": 0, "avg_duration_ms": 0}'
        else
            log_info "No metrics found"
        fi
        return 0
    fi

    local summary
    summary=$(cat "$METRICS_DB" | jq -s '{
        total: length,
        success: [.[] | select(.workflow_status == "success")] | length,
        error: [.[] | select(.workflow_status == "error")] | length,
        avg_duration_ms: ([.[] | .total_duration_ms] | add / length | floor),
        total_files_written: ([.[] | .files_written] | add),
        total_commits: ([.[] | .commits] | add),
        total_errors: ([.[] | .errors] | add)
    }')

    if [ "$json_output" = "true" ]; then
        echo "$summary"
    else
        echo ""
        echo "=== Container Metrics Summary ==="
        echo ""
        echo "Total runs:        $(echo "$summary" | jq -r '.total')"
        echo "Successful:        $(echo "$summary" | jq -r '.success')"
        echo "Failed:            $(echo "$summary" | jq -r '.error')"
        echo "Avg duration:      $(($(echo "$summary" | jq -r '.avg_duration_ms') / 1000))s"
        echo "Total files:       $(echo "$summary" | jq -r '.total_files_written')"
        echo "Total commits:     $(echo "$summary" | jq -r '.total_commits')"
        echo ""
    fi
}

# Main
main() {
    case "${1:-}" in
        --help|-h)
            usage
            exit 0
            ;;
        --all)
            persist_all
            ;;
        --query)
            shift
            query_metrics "$@"
            ;;
        --summary)
            get_summary "${2:-false}"
            ;;
        "")
            usage
            exit 1
            ;;
        *)
            # Assume it's an issue number
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                persist_issue "$1"
            else
                log_error "Unknown option: $1"
                usage
                exit 1
            fi
            ;;
    esac
}

main "$@"
