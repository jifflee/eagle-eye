#!/bin/bash
set -euo pipefail
# container-status.sh
# Check status of running sprint-work containers
#
# Usage:
#   ./scripts/container-status.sh              # List all containers
#   ./scripts/container-status.sh 211          # Check specific issue
#   ./scripts/container-status.sh --json       # JSON output for sprint-status
#   ./scripts/container-status.sh --summary    # Brief summary only
#
# Exit codes:
#   0 = Success
#   1 = No containers found / Error

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Remote connection defaults
DEFAULT_REMOTE_HOST="docker-workers"
DEFAULT_SSH_KEY="$HOME/.ssh/id_ed25519_proxmox_bootstrap"
DEFAULT_SSH_USER="ubuntu"

# Parse arguments
ISSUE=""
JSON_OUTPUT="false"
SUMMARY_ONLY="false"
REMOTE_MODE="false"
REMOTE_HOST="${REMOTE_DOCKER_HOST:-$DEFAULT_REMOTE_HOST}"
SSH_KEY="${REMOTE_SSH_KEY:-$DEFAULT_SSH_KEY}"
SSH_USER="${REMOTE_SSH_USER:-$DEFAULT_SSH_USER}"

while [ $# -gt 0 ]; do
    case "$1" in
        --json)
            JSON_OUTPUT="true"
            shift
            ;;
        --summary)
            SUMMARY_ONLY="true"
            shift
            ;;
        --remote)
            REMOTE_MODE="true"
            # Optional: --remote <host>
            if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]]; then
                REMOTE_HOST="$2"
                shift 2
            else
                shift
            fi
            ;;
        --remote-host)
            REMOTE_HOST="$2"
            shift 2
            ;;
        --remote-key)
            SSH_KEY="$2"
            shift 2
            ;;
        --remote-user)
            SSH_USER="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [issue] [--json] [--summary] [--remote [host]]"
            echo ""
            echo "Options:"
            echo "  issue             Check specific issue number"
            echo "  --json            Output JSON for integration with sprint-status"
            echo "  --summary         Brief summary only"
            echo "  --remote [host]   Query remote Docker host via SSH (default: docker-workers)"
            echo "  --remote-host     Specify remote host"
            echo "  --remote-key      SSH key path (default: ~/.ssh/id_ed25519_proxmox_bootstrap)"
            echo "  --remote-user     SSH user (default: ubuntu)"
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                ISSUE="$1"
            fi
            shift
            ;;
    esac
done

# Build SSH command for remote execution
build_ssh_cmd() {
    local host="$1"
    local key="$2"
    local user="$3"
    echo "ssh -i ${key} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes ${user}@${host}"
}

# Get container info (local or remote)
get_container_info() {
    local filter="$1"

    if [ "$REMOTE_MODE" = "true" ]; then
        # Query remote Docker host via SSH
        local ssh_cmd
        ssh_cmd=$(build_ssh_cmd "$REMOTE_HOST" "$SSH_KEY" "$SSH_USER")
        $ssh_cmd "docker ps -a --filter 'name=${CONTAINER_PREFIX}${filter}' \
            --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}\t{{.State}}' 2>/dev/null" 2>/dev/null || echo ""
    else
        # Query local Docker
        docker ps -a --filter "name=${CONTAINER_PREFIX}${filter}" \
            --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}\t{{.State}}' 2>/dev/null || echo ""
    fi
}

# Parse container name to get issue number
parse_issue_number() {
    local name="$1"
    echo "$name" | sed "s/${CONTAINER_PREFIX}-//"
}

# Calculate age in hours
calculate_age() {
    local created="$1"
    local now=$(date +%s)
    local created_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$created" +%s 2>/dev/null || echo "$now")
    local age_secs=$((now - created_ts))
    echo $((age_secs / 3600))
}

# Get last activity from logs (local or remote)
get_last_activity() {
    local name="$1"
    local last_log
    if [ "$REMOTE_MODE" = "true" ]; then
        local ssh_cmd
        ssh_cmd=$(build_ssh_cmd "$REMOTE_HOST" "$SSH_KEY" "$SSH_USER")
        last_log=$($ssh_cmd "docker logs --tail 1 --timestamps '${name}' 2>/dev/null | head -1" 2>/dev/null || echo "")
    else
        last_log=$(docker logs --tail 1 --timestamps "$name" 2>/dev/null | head -1)
    fi
    if [ -n "$last_log" ]; then
        echo "$last_log" | cut -d' ' -f1 | cut -d'.' -f1
    else
        echo ""
    fi
}

# Get heartbeat info from container (Issue #508) - local or remote
get_heartbeat_info() {
    local name="$1"

    # Try to read heartbeat file from container
    local heartbeat_json
    if [ "$REMOTE_MODE" = "true" ]; then
        local ssh_cmd
        ssh_cmd=$(build_ssh_cmd "$REMOTE_HOST" "$SSH_KEY" "$SSH_USER")
        heartbeat_json=$($ssh_cmd "docker exec '${name}' cat /tmp/heartbeat 2>/dev/null || echo ''" 2>/dev/null || echo "")
    else
        heartbeat_json=$(docker exec "$name" cat /tmp/heartbeat 2>/dev/null || echo "")
    fi

    if [ -z "$heartbeat_json" ]; then
        echo '{"available": false}'
        return
    fi

    # Parse and calculate age
    local timestamp
    timestamp=$(echo "$heartbeat_json" | jq -r '.timestamp // empty' 2>/dev/null)

    if [ -z "$timestamp" ]; then
        echo '{"available": false}'
        return
    fi

    local now_epoch
    local hb_epoch
    now_epoch=$(date +%s)
    hb_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || \
               date -d "$timestamp" +%s 2>/dev/null || echo "$now_epoch")

    local age=$((now_epoch - hb_epoch))

    # Extract phase and action
    local phase action
    phase=$(echo "$heartbeat_json" | jq -r '.phase // "unknown"' 2>/dev/null)
    action=$(echo "$heartbeat_json" | jq -r '.action // ""' 2>/dev/null)

    jq -n \
        --argjson available true \
        --argjson age "$age" \
        --arg phase "$phase" \
        --arg action "$action" \
        --arg timestamp "$timestamp" \
        '{available: $available, age_seconds: $age, phase: $phase, action: $action, timestamp: $timestamp}'
}

# Format heartbeat age for display
format_heartbeat_age() {
    local age="$1"

    if [ "$age" -lt 60 ]; then
        echo "${age}s"
    elif [ "$age" -lt 3600 ]; then
        echo "$((age / 60))m"
    else
        echo "$((age / 3600))h"
    fi
}

# Check if container has completed successfully (look for PR URL in logs)
check_completion() {
    local name="$1"
    local logs
    if [ "$REMOTE_MODE" = "true" ]; then
        local ssh_cmd
        ssh_cmd=$(build_ssh_cmd "$REMOTE_HOST" "$SSH_KEY" "$SSH_USER")
        logs=$($ssh_cmd "docker logs '${name}' 2>/dev/null | tail -50" 2>/dev/null || echo "")
    else
        logs=$(docker logs "$name" 2>/dev/null | tail -50)
    fi

    # Check for PR creation
    if echo "$logs" | grep -q "PR created:"; then
        local pr_url=$(echo "$logs" | grep "PR created:" | tail -1 | sed 's/.*PR created: //')
        echo "completed:$pr_url"
        return 0
    fi

    # Check for workflow complete message
    if echo "$logs" | grep -q "CONTAINER SPRINT WORKFLOW COMPLETE"; then
        echo "completed"
        return 0
    fi

    # Check for errors
    if echo "$logs" | grep -q "\[ERROR\]"; then
        echo "error"
        return 0
    fi

    echo "running"
}

# Build JSON output
build_json() {
    local containers=()
    local running=0
    local stopped=0
    local failed=0
    local orphans=0
    local orphan_threshold=24  # hours

    while IFS=$'\t' read -r name status created state; do
        [ -z "$name" ] && continue

        local issue_num=$(parse_issue_number "$name")
        local age_hours=$(calculate_age "${created% *}")
        local last_activity=$(get_last_activity "$name")
        local completion_status=""
        local pr_url=""

        # Get heartbeat info (Issue #508)
        local heartbeat_json='{"available": false}'
        local heartbeat_age="null"
        local heartbeat_phase='""'

        # Determine status
        if [ "$state" = "running" ]; then
            running=$((running + 1))
            completion_status=$(check_completion "$name")
            if [ $age_hours -gt $orphan_threshold ]; then
                orphans=$((orphans + 1))
            fi

            # Get heartbeat for running containers
            heartbeat_json=$(get_heartbeat_info "$name")
            if [ "$(echo "$heartbeat_json" | jq -r '.available')" = "true" ]; then
                heartbeat_age=$(echo "$heartbeat_json" | jq -r '.age_seconds')
                heartbeat_phase=$(echo "$heartbeat_json" | jq -r '.phase')
            fi
        elif [ "$state" = "exited" ]; then
            local exit_code
            if [ "$REMOTE_MODE" = "true" ]; then
                local ssh_cmd_inner
                ssh_cmd_inner=$(build_ssh_cmd "$REMOTE_HOST" "$SSH_KEY" "$SSH_USER")
                exit_code=$($ssh_cmd_inner "docker inspect '${name}' --format '{{.State.ExitCode}}' 2>/dev/null || echo '1'" 2>/dev/null || echo "1")
            else
                exit_code=$(docker inspect "$name" --format '{{.State.ExitCode}}' 2>/dev/null || echo "1")
            fi
            if [ "$exit_code" = "0" ]; then
                stopped=$((stopped + 1))
                completion_status=$(check_completion "$name")
            else
                failed=$((failed + 1))
                completion_status="failed:$exit_code"
            fi
        fi

        # Extract PR URL if present
        if [[ "$completion_status" == completed:* ]]; then
            pr_url="${completion_status#completed:}"
            completion_status="completed"
        fi

        local remote_host_field=""
        [ "$REMOTE_MODE" = "true" ] && remote_host_field=",\"remote_host\":\"${REMOTE_HOST}\""

        containers+=("{\"issue\":$issue_num,\"name\":\"$name\",\"status\":\"$state\",\"age_hours\":$age_hours,\"last_activity\":\"$last_activity\",\"completion\":\"$completion_status\",\"pr_url\":\"$pr_url\",\"heartbeat\":{\"age_seconds\":${heartbeat_age:-null},\"phase\":\"${heartbeat_phase}\"}${remote_host_field}}")
    done < <(get_container_info "${ISSUE:+-$ISSUE}")

    # Build JSON
    local containers_json=$(IFS=,; echo "${containers[*]}")
    local remote_field=""
    [ "$REMOTE_MODE" = "true" ] && remote_field="\"remote_host\": \"${REMOTE_HOST}\","
    cat <<EOF
{
  ${remote_field}
  "containers": [${containers_json}],
  "summary": {
    "total": ${#containers[@]},
    "running": $running,
    "stopped": $stopped,
    "failed": $failed,
    "orphans": $orphans,
    "orphan_threshold_hours": $orphan_threshold
  }
}
EOF
}

# Display human-readable output
display_containers() {
    local found=0

    if [ "$SUMMARY_ONLY" = "true" ]; then
        local running total
        if [ "$REMOTE_MODE" = "true" ]; then
            local ssh_cmd
            ssh_cmd=$(build_ssh_cmd "$REMOTE_HOST" "$SSH_KEY" "$SSH_USER")
            running=$($ssh_cmd "docker ps --filter 'name=${CONTAINER_PREFIX}' --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo "0")
            total=$($ssh_cmd "docker ps -a --filter 'name=${CONTAINER_PREFIX}' --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo "0")
        else
            running=$(docker ps --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
            total=$(docker ps -a --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
        fi
        local location_str=""
        [ "$REMOTE_MODE" = "true" ] && location_str=" (remote: ${REMOTE_HOST})"
        echo "Containers${location_str}: $running running, $((total - running)) stopped"
        return 0
    fi

    echo ""
    if [ "$REMOTE_MODE" = "true" ]; then
        echo -e "${BLUE}=== Container Status (Remote: ${REMOTE_HOST}) ===${NC}"
    else
        echo -e "${BLUE}=== Container Status ===${NC}"
    fi
    echo ""

    printf "%-25s %-12s %-8s %-10s %-12s %s\n" "CONTAINER" "STATUS" "AGE" "HEARTBEAT" "PHASE" "RESULT"
    printf "%-25s %-12s %-8s %-10s %-12s %s\n" "---------" "------" "---" "---------" "-----" "------"

    while IFS=$'\t' read -r name status created state; do
        [ -z "$name" ] && continue
        found=1

        local issue_num=$(parse_issue_number "$name")
        local age_hours=$(calculate_age "${created% *}")
        local last_activity=$(get_last_activity "$name")
        local completion=$(check_completion "$name")

        # Get heartbeat info (Issue #508)
        local heartbeat_str="-"
        local phase_str="-"

        # Color status
        local status_color
        case "$state" in
            running)
                status_color="${GREEN}running${NC}"

                # Get heartbeat for running containers
                local hb_info
                hb_info=$(get_heartbeat_info "$name")
                if [ "$(echo "$hb_info" | jq -r '.available')" = "true" ]; then
                    local hb_age
                    hb_age=$(echo "$hb_info" | jq -r '.age_seconds')
                    heartbeat_str=$(format_heartbeat_age "$hb_age")
                    phase_str=$(echo "$hb_info" | jq -r '.phase // "-"')

                    # Color heartbeat based on age (stale = warning)
                    if [ "$hb_age" -gt 120 ]; then
                        heartbeat_str="${RED}${heartbeat_str}${NC}"
                    elif [ "$hb_age" -gt 60 ]; then
                        heartbeat_str="${YELLOW}${heartbeat_str}${NC}"
                    else
                        heartbeat_str="${GREEN}${heartbeat_str}${NC}"
                    fi
                fi
                ;;
            exited)
                local exit_code
                if [ "$REMOTE_MODE" = "true" ]; then
                    local ssh_cmd_e
                    ssh_cmd_e=$(build_ssh_cmd "$REMOTE_HOST" "$SSH_KEY" "$SSH_USER")
                    exit_code=$($ssh_cmd_e "docker inspect '${name}' --format '{{.State.ExitCode}}' 2>/dev/null || echo '1'" 2>/dev/null || echo "1")
                else
                    exit_code=$(docker inspect "$name" --format '{{.State.ExitCode}}' 2>/dev/null || echo "1")
                fi
                if [ "$exit_code" = "0" ]; then
                    status_color="${GREEN}completed${NC}"
                else
                    status_color="${RED}failed($exit_code)${NC}"
                fi
                ;;
            *) status_color="${YELLOW}$state${NC}" ;;
        esac

        # Format age
        local age_str
        if [ $age_hours -lt 1 ]; then
            age_str="<1h"
        else
            age_str="${age_hours}h"
        fi

        # Color completion result
        local result_color
        case "$completion" in
            completed*) result_color="${GREEN}PR created${NC}" ;;
            error) result_color="${RED}error${NC}" ;;
            running) result_color="${YELLOW}in progress${NC}" ;;
            failed*) result_color="${RED}$completion${NC}" ;;
            *) result_color="$completion" ;;
        esac

        # Truncate phase
        phase_str="${phase_str:0:12}"

        printf "%-25s %-12b %-8s %-10b %-12s %b\n" "$name" "$status_color" "$age_str" "$heartbeat_str" "$phase_str" "$result_color"
    done < <(get_container_info "${ISSUE:+-$ISSUE}")

    if [ $found -eq 0 ]; then
        if [ -n "$ISSUE" ]; then
            echo "No container found for issue #$ISSUE"
        else
            echo "No sprint-work containers found"
        fi
        return 1
    fi

    echo ""
    echo "Commands:"
    echo "  View logs:  docker logs -f claude-tastic-issue-<N>"
    echo "  Stop:       ./scripts/container-launch.sh --stop <N>"
    echo "  Cleanup:    ./scripts/container-launch.sh --cleanup"
}

# Main
if [ "$JSON_OUTPUT" = "true" ]; then
    build_json
else
    display_containers
fi
