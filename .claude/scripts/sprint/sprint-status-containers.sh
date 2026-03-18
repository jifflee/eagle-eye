#!/bin/bash
set -euo pipefail
# sprint-status-containers.sh
# Gather container status data for sprint-status integration
# Part of Phase 5: Automatic container cleanup (Issue #135)
#
# Output: JSON object with container status suitable for sprint-status display
#
# Usage:
#   ./scripts/sprint-status-containers.sh
#   ./scripts/sprint-status-containers.sh --include-history

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/framework-config.sh"
ORPHAN_THRESHOLD_HOURS=24
LOG_DIR="${HOME}/.claude-tastic/logs"
INCLUDE_HISTORY="false"

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --include-history)
            INCLUDE_HISTORY="true"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo '{"available": false, "error": "Docker not installed", "containers": [], "summary": {}}'
    exit 0
fi

if ! docker info &> /dev/null 2>&1; then
    echo '{"available": false, "error": "Docker daemon not running", "containers": [], "summary": {}}'
    exit 0
fi

# Get container age in hours
get_container_age_hours() {
    local container="$1"
    local created_at
    created_at=$(docker inspect --format '{{.Created}}' "$container" 2>/dev/null)

    if [ -z "$created_at" ]; then
        echo "0"
        return
    fi

    # Try macOS date format first, then Linux
    local created_timestamp
    created_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${created_at:0:19}" "+%s" 2>/dev/null || \
                       date -d "${created_at:0:19}" "+%s" 2>/dev/null || echo "0")

    local now_timestamp
    now_timestamp=$(date "+%s")

    local age_seconds=$((now_timestamp - created_timestamp))
    local age_hours=$((age_seconds / 3600))

    echo "$age_hours"
}

# Get last activity (approximated by container start time)
get_last_activity() {
    local container="$1"
    local started_at
    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null)

    if [ -z "$started_at" ] || [ "$started_at" = "0001-01-01T00:00:00Z" ]; then
        echo "unknown"
        return
    fi

    # Calculate minutes ago
    local started_timestamp
    started_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${started_at:0:19}" "+%s" 2>/dev/null || \
                       date -d "${started_at:0:19}" "+%s" 2>/dev/null || echo "0")

    local now_timestamp
    now_timestamp=$(date "+%s")

    local age_seconds=$((now_timestamp - started_timestamp))
    local age_minutes=$((age_seconds / 60))

    if [ "$age_minutes" -lt 60 ]; then
        echo "${age_minutes}m ago"
    elif [ "$age_minutes" -lt 1440 ]; then
        echo "$((age_minutes / 60))h ago"
    else
        echo "$((age_minutes / 1440))d ago"
    fi
}

# Get heartbeat age in seconds (time since last log activity)
get_heartbeat_age() {
    local container="$1"

    # Get timestamp from last log line
    local last_log_ts
    last_log_ts=$(docker logs --tail 1 --timestamps "$container" 2>/dev/null | head -1 | cut -d' ' -f1 2>/dev/null)

    if [ -z "$last_log_ts" ]; then
        echo "-1"
        return
    fi

    # Parse timestamp and calculate age
    local log_timestamp
    log_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_log_ts:0:19}" "+%s" 2>/dev/null || \
                   date -d "${last_log_ts:0:19}" "+%s" 2>/dev/null || echo "0")

    if [ "$log_timestamp" = "0" ]; then
        echo "-1"
        return
    fi

    local now_timestamp
    now_timestamp=$(date "+%s")

    echo $((now_timestamp - log_timestamp))
}

# Get current workflow phase from container logs
get_current_phase() {
    local container="$1"

    # Look for phase markers in recent logs
    local logs
    logs=$(docker logs --tail 100 "$container" 2>/dev/null)

    if echo "$logs" | grep -q "PHASE: implement" || echo "$logs" | grep -q "Starting implementation"; then
        echo "implement"
    elif echo "$logs" | grep -q "PHASE: test" || echo "$logs" | grep -q "Running tests"; then
        echo "test"
    elif echo "$logs" | grep -q "PHASE: review" || echo "$logs" | grep -q "Creating PR"; then
        echo "review"
    elif echo "$logs" | grep -q "PHASE: complete" || echo "$logs" | grep -q "CONTAINER SPRINT WORKFLOW COMPLETE"; then
        echo "complete"
    elif echo "$logs" | grep -q "PHASE: init" || echo "$logs" | grep -q "Initializing"; then
        echo "init"
    else
        echo "-"
    fi
}

# Get CPU and memory usage from docker stats
get_resource_stats() {
    local container="$1"

    # Get stats with no-stream for instant snapshot
    # Format: container,cpu%,memory
    local stats
    stats=$(docker stats --no-stream --format "{{.CPUPerc}}\t{{.MemUsage}}" "$container" 2>/dev/null)

    if [ -z "$stats" ]; then
        echo "0%\t0MB"
        return
    fi

    echo "$stats"
}

# Get issue number from container name
get_issue_number() {
    local container="$1"
    echo "${container#${CONTAINER_PREFIX}-}"
}

# Build containers JSON array
build_containers_json() {
    local containers
    containers=$(docker ps -a --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null)

    if [ -z "$containers" ]; then
        echo "[]"
        return
    fi

    local first=true
    echo "["

    while IFS= read -r container; do
        local status
        status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")

        local exit_code
        exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "-1")

        local age_hours
        age_hours=$(get_container_age_hours "$container")

        local last_activity
        last_activity=$(get_last_activity "$container")

        local issue_num
        issue_num=$(get_issue_number "$container")

        local image
        image=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || echo "unknown")

        # Get enhanced health metrics
        local heartbeat_age_secs=-1
        local current_phase="-"
        local cpu_percent="0%"
        local memory_usage="0MB"

        if [ "$status" = "running" ]; then
            heartbeat_age_secs=$(get_heartbeat_age "$container")
            current_phase=$(get_current_phase "$container")

            # Get resource stats
            local stats
            stats=$(get_resource_stats "$container")
            cpu_percent=$(echo "$stats" | cut -f1)
            memory_usage=$(echo "$stats" | cut -f2 | sed 's/ \/.*//')  # Extract used memory only
        fi

        # Determine if orphan
        local is_orphan="false"
        if [ "$status" = "running" ] && [ "$age_hours" -ge "$ORPHAN_THRESHOLD_HOURS" ]; then
            is_orphan="true"
        fi

        # Determine enhanced health status based on heartbeat thresholds
        local health="ok"
        local health_indicator="🟢"

        if [ "$status" = "exited" ] && [ "$exit_code" != "0" ]; then
            health="failed"
            health_indicator="🔴"
        elif [ "$status" = "exited" ]; then
            health="stopped"
            health_indicator="⚪"
        elif [ "$is_orphan" = "true" ]; then
            health="orphan"
            health_indicator="🔴"
        elif [ "$status" = "running" ]; then
            # Apply heartbeat-based health thresholds
            if [ "$heartbeat_age_secs" -ge 120 ]; then
                health="unhealthy"
                health_indicator="🔴"
            elif [ "$heartbeat_age_secs" -ge 60 ]; then
                health="warning"
                health_indicator="🟡"
            else
                health="healthy"
                health_indicator="🟢"
            fi
        fi

        if [ "$first" = "true" ]; then
            first=false
        else
            echo ","
        fi

        cat << EOF
    {
      "name": "$container",
      "issue": "$issue_num",
      "status": "$status",
      "exit_code": $exit_code,
      "age_hours": $age_hours,
      "last_activity": "$last_activity",
      "image": "$image",
      "is_orphan": $is_orphan,
      "health": "$health",
      "health_indicator": "$health_indicator",
      "heartbeat_age_secs": $heartbeat_age_secs,
      "current_phase": "$current_phase",
      "cpu_percent": "$cpu_percent",
      "memory_usage": "$memory_usage"
    }
EOF
    done <<< "$containers"

    echo ""
    echo "  ]"
}

# Build summary counts
build_summary() {
    local containers
    containers=$(docker ps -a --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null)

    local running=0
    local stopped=0
    local failed=0
    local orphans=0
    local healthy=0
    local warning=0
    local unhealthy=0
    local total=0

    if [ -n "$containers" ]; then
        while IFS= read -r container; do
            ((total++))

            local status
            status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")

            local exit_code
            exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "0")

            local age_hours
            age_hours=$(get_container_age_hours "$container")

            if [ "$status" = "running" ]; then
                ((running++))

                # Check heartbeat for health status
                local heartbeat_age
                heartbeat_age=$(get_heartbeat_age "$container")

                if [ "$age_hours" -ge "$ORPHAN_THRESHOLD_HOURS" ]; then
                    ((orphans++))
                    ((unhealthy++))
                elif [ "$heartbeat_age" -ge 120 ]; then
                    ((unhealthy++))
                elif [ "$heartbeat_age" -ge 60 ]; then
                    ((warning++))
                else
                    ((healthy++))
                fi
            elif [ "$status" = "exited" ]; then
                if [ "$exit_code" != "0" ]; then
                    ((failed++))
                else
                    ((stopped++))
                fi
            fi
        done <<< "$containers"
    fi

    cat << EOF
{
    "total": $total,
    "running": $running,
    "stopped": $stopped,
    "failed": $failed,
    "orphans": $orphans,
    "healthy": $healthy,
    "warning": $warning,
    "unhealthy": $unhealthy,
    "orphan_threshold_hours": $ORPHAN_THRESHOLD_HOURS
  }
EOF
}

# Get recent cleanup history
get_cleanup_history() {
    local audit_file="$LOG_DIR/container-cleanup.log"

    if [ ! -f "$audit_file" ]; then
        echo "[]"
        return
    fi

    echo "["
    local first=true

    # Get last 10 entries
    tail -10 "$audit_file" 2>/dev/null | while IFS='|' read -r timestamp action container details outcome; do
        if [ -n "$timestamp" ]; then
            if [ "$first" = "true" ]; then
                first=false
            else
                echo ","
            fi

            cat << EOF
    {
      "timestamp": "$timestamp",
      "action": "$action",
      "container": "$container",
      "details": "$details",
      "outcome": "$outcome"
    }
EOF
        fi
    done

    echo ""
    echo "  ]"
}

# Main output
main() {
    local containers_json
    containers_json=$(build_containers_json)

    local summary_json
    summary_json=$(build_summary)

    # Start JSON output
    echo "{"
    echo '  "available": true,'
    echo '  "containers": '"$containers_json"','
    echo '  "summary": '"$summary_json"

    if [ "$INCLUDE_HISTORY" = "true" ]; then
        local history_json
        history_json=$(get_cleanup_history)
        echo ','
        echo '  "cleanup_history": '"$history_json"
    fi

    echo "}"
}

main
