#!/bin/bash
set -euo pipefail
# container-result.sh
# Captures the result from a completed container sprint-work run
#
# Usage:
#   ./scripts/container-result.sh <issue_number>
#   ./scripts/container-result.sh --all
#   ./scripts/container-result.sh <issue_number> --extract-actions
#
# Output: JSON with status, PR URL, and issue info
#         With --extract-actions: appends action logs to .claude/actions.jsonl

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/framework-config.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Remote connection defaults
DEFAULT_REMOTE_HOST="docker-workers"
DEFAULT_SSH_KEY="$HOME/.ssh/id_ed25519_proxmox_bootstrap"
DEFAULT_SSH_USER="ubuntu"

# Remote mode state (set by --remote flag)
REMOTE_MODE="false"
REMOTE_HOST="${REMOTE_DOCKER_HOST:-$DEFAULT_REMOTE_HOST}"
SSH_KEY="${REMOTE_SSH_KEY:-$DEFAULT_SSH_KEY}"
SSH_USER="${REMOTE_SSH_USER:-$DEFAULT_SSH_USER}"

# Build SSH command for remote execution
build_ssh_cmd() {
    local host="$1"
    local key="$2"
    local user="$3"
    echo "ssh -i ${key} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes ${user}@${host}"
}

# Run docker command locally or remotely
docker_cmd() {
    if [ "$REMOTE_MODE" = "true" ]; then
        local ssh_cmd
        ssh_cmd=$(build_ssh_cmd "$REMOTE_HOST" "$SSH_KEY" "$SSH_USER")
        $ssh_cmd "docker $*" 2>/dev/null
    else
        docker "$@" 2>/dev/null
    fi
}

# Extract action logs from container and append to main log
extract_action_logs() {
    local container_name="$1"
    local actions_file="$REPO_ROOT/.claude/actions.jsonl"

    # Ensure directory exists
    mkdir -p "$REPO_ROOT/.claude"

    # Extract ACTION_LOG markers and append
    local count=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^ACTION_LOG= ]]; then
            local json_entry="${line#ACTION_LOG=}"
            echo "$json_entry" >> "$actions_file"
            count=$((count + 1))
        fi
    done < <(docker_cmd logs "$container_name" 2>&1)

    echo "$count"
}

# Parse arguments - support --remote flag
POSITIONAL_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --remote)
            REMOTE_MODE="true"
            # Optional: --remote <host>
            if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]] && [ "$2" != "--all" ] && ! [[ "$2" =~ ^[0-9]+$ ]]; then
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
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
# Restore positional args
set -- "${POSITIONAL_ARGS[@]}"

if [ "${1:-}" = "--all" ]; then
    # Show results for all stopped containers
    containers=$(docker_cmd ps -a --filter "name=${CONTAINER_PREFIX}" --filter "status=exited" --format '{{.Names}}')
    if [ -z "$containers" ]; then
        echo '{"results":[],"message":"No completed containers found"}'
        exit 0
    fi
    echo '{"results":['
    first=true
    while IFS= read -r name; do
        issue=$(echo "$name" | sed "s/${CONTAINER_PREFIX}-//")
        result=$(docker_cmd logs "$name" 2>&1 | grep "^SPRINT_RESULT=" | tail -1 | cut -d'=' -f2-)
        if [ -z "$result" ]; then
            result="{\"status\":\"unknown\",\"issue\":$issue,\"message\":\"No result found in logs\"}"
        fi
        if [ "$first" = "true" ]; then
            first=false
        else
            echo ","
        fi
        echo "  $result"
    done <<< "$containers"
    echo ']}'
    exit 0
fi

if [ -z "${1:-}" ]; then
    echo "Usage: $0 [--remote [host]] <issue_number> | --all [--extract-actions]" >&2
    exit 1
fi

ISSUE="$1"
EXTRACT_ACTIONS=false
if [ "${2:-}" = "--extract-actions" ]; then
    EXTRACT_ACTIONS=true
fi
NAME="${CONTAINER_PREFIX}-${ISSUE}"

# Add remote host info to output if in remote mode
REMOTE_FIELD=""
[ "$REMOTE_MODE" = "true" ] && REMOTE_FIELD=",\"remote_host\":\"${REMOTE_HOST}\""

# Check if container exists (running or stopped)
if ! docker_cmd ps -a --filter "name=^${NAME}$" --format '{{.Names}}' | grep -q "^${NAME}$"; then
    echo "{\"status\":\"not_found\",\"issue\":$ISSUE,\"message\":\"Container $NAME not found\"${REMOTE_FIELD}}"
    exit 1
fi

# Check container status
STATUS=$(docker_cmd inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null || echo "removed")
EXIT_CODE=$(docker_cmd inspect "$NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo "-1")

if [ "$STATUS" = "running" ]; then
    echo "{\"status\":\"running\",\"issue\":$ISSUE,\"message\":\"Container still running\"${REMOTE_FIELD}}"
    exit 0
fi

# Extract action logs if requested (only supported for local containers)
ACTION_LOG_COUNT=0
if [ "$EXTRACT_ACTIONS" = "true" ] && [ "$REMOTE_MODE" = "false" ]; then
    ACTION_LOG_COUNT=$(extract_action_logs "$NAME")
elif [ "$EXTRACT_ACTIONS" = "true" ] && [ "$REMOTE_MODE" = "true" ]; then
    echo "Warning: --extract-actions not supported for remote containers" >&2
fi

# Extract result from logs
RESULT=$(docker_cmd logs "$NAME" 2>&1 | grep "^SPRINT_RESULT=" | tail -1 | cut -d'=' -f2-)

if [ -n "$RESULT" ]; then
    # Add action log count to result if extracted
    if [ "$EXTRACT_ACTIONS" = "true" ] && [ "$ACTION_LOG_COUNT" -gt 0 ]; then
        RESULT=$(echo "$RESULT" | jq --argjson count "$ACTION_LOG_COUNT" '. + {action_logs_extracted: $count}')
    fi
    # Add remote host info if applicable
    if [ "$REMOTE_MODE" = "true" ]; then
        RESULT=$(echo "$RESULT" | jq --arg host "$REMOTE_HOST" '. + {remote_host: $host}' 2>/dev/null || echo "$RESULT")
    fi
    echo "$RESULT"
else
    if [ "$EXTRACT_ACTIONS" = "true" ] && [ "$ACTION_LOG_COUNT" -gt 0 ]; then
        echo "{\"status\":\"completed\",\"issue\":$ISSUE,\"exit_code\":$EXIT_CODE,\"action_logs_extracted\":$ACTION_LOG_COUNT,\"message\":\"No structured result found\"${REMOTE_FIELD}}"
    else
        echo "{\"status\":\"completed\",\"issue\":$ISSUE,\"exit_code\":$EXIT_CODE,\"message\":\"No structured result found\"${REMOTE_FIELD}}"
    fi
fi
