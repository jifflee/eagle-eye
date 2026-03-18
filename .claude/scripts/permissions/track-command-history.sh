#!/bin/bash
# track-command-history.sh
# Track command execution history for context-aware risk assessment
# Part of Issue #597: Context-aware risk assessment for Permission Decision Engine
#
# Usage:
#   ./track-command-history.sh --record --command "git push" --success
#   echo '{"command":"git push"}' | ./track-command-history.sh --check
#
# Output: JSON with command history stats

set -euo pipefail

HISTORY_DIR="${HISTORY_DIR:-$HOME/.claude-tastic/command-history}"
SESSION_ID="${SESSION_ID:-$(date +%Y%m%d)}"

mkdir -p "$HISTORY_DIR"

# Parse input
MODE="check"
COMMAND=""
SUCCESS=""

# Parse command-line args first
while [ $# -gt 0 ]; do
    case "$1" in
        --record) MODE="record"; shift ;;
        --check) MODE="check"; shift ;;
        --stats) MODE="stats"; shift ;;
        --cleanup) MODE="cleanup"; shift ;;
        --command) COMMAND="$2"; shift 2 ;;
        --success) SUCCESS="true"; shift ;;
        --failure) SUCCESS="false"; shift ;;
        *) shift ;;
    esac
done

# If no command from args, try stdin
if [ -z "$COMMAND" ] && [ ! -t 0 ]; then
    INPUT=$(cat)
    COMMAND=$(echo "$INPUT" | jq -r '.command // ""')
    SUCCESS=$(echo "$INPUT" | jq -r '.success // ""')
    # Only override MODE if explicitly set in JSON
    json_mode=$(echo "$INPUT" | jq -r '.mode // ""')
    if [ -n "$json_mode" ] && [ "$json_mode" != "null" ]; then
        MODE="$json_mode"
    fi
fi

# Create a hash key from command (first 50 chars, normalized)
get_command_key() {
    local cmd="$1"
    # Normalize: remove variable parts (numbers, paths)
    local normalized
    normalized=$(echo "$cmd" | sed 's/[0-9]\+/N/g' | sed 's/"[^"]*"/"STR"/g')
    echo "${normalized:0:50}" | md5sum | cut -d' ' -f1 2>/dev/null || echo "${normalized:0:50}" | md5 2>/dev/null || echo "unknown"
}

# Record command execution
record_command() {
    local cmd="$1"
    local success="$2"
    local key
    key=$(get_command_key "$cmd")
    local history_file="$HISTORY_DIR/${key}.json"

    # Load existing history or create new
    local history
    if [ -f "$history_file" ]; then
        history=$(cat "$history_file")
    else
        history='{"command_pattern":"","success_count":0,"failure_count":0,"last_success":"","last_failure":"","total_executions":0}'
    fi

    # Update counters
    local success_count
    local failure_count
    local total
    success_count=$(echo "$history" | jq -r '.success_count')
    failure_count=$(echo "$history" | jq -r '.failure_count')
    total=$(echo "$history" | jq -r '.total_executions')

    if [ "$success" = "true" ]; then
        success_count=$((success_count + 1))
        history=$(echo "$history" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_success = $ts')
    else
        failure_count=$((failure_count + 1))
        history=$(echo "$history" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_failure = $ts')
    fi
    total=$((total + 1))

    # Update history
    history=$(echo "$history" | jq \
        --arg cmd "${cmd:0:100}" \
        --arg sc "$success_count" \
        --arg fc "$failure_count" \
        --arg total "$total" \
        '.command_pattern = $cmd | .success_count = ($sc | tonumber) | .failure_count = ($fc | tonumber) | .total_executions = ($total | tonumber)')

    # Save
    echo "$history" > "$history_file"

    # Output confirmation
    echo "$history"
}

# Check command history
check_command() {
    local cmd="$1"
    local key
    key=$(get_command_key "$cmd")
    local history_file="$HISTORY_DIR/${key}.json"

    if [ -f "$history_file" ]; then
        cat "$history_file"
    else
        jq -n \
            --arg cmd "${cmd:0:100}" \
            '{
                command_pattern: $cmd,
                success_count: 0,
                failure_count: 0,
                last_success: "",
                last_failure: "",
                total_executions: 0,
                is_new: true
            }'
    fi
}

# Get session statistics
session_stats() {
    local total_commands=0
    local total_successes=0
    local total_failures=0

    # Count files modified today
    local files
    files=$(find "$HISTORY_DIR" -name "*.json" -mtime -1 2>/dev/null || echo "")

    while IFS= read -r file; do
        [ -z "$file" ] && continue
        local history
        history=$(cat "$file" 2>/dev/null || echo '{}')
        local sc
        local fc
        sc=$(echo "$history" | jq -r '.success_count // 0')
        fc=$(echo "$history" | jq -r '.failure_count // 0')
        total_successes=$((total_successes + sc))
        total_failures=$((total_failures + fc))
        total_commands=$((total_commands + 1))
    done <<< "$files"

    jq -n \
        --arg total "$total_commands" \
        --arg success "$total_successes" \
        --arg failure "$total_failures" \
        '{
            session_id: env.SESSION_ID,
            unique_commands: ($total | tonumber),
            total_successes: ($success | tonumber),
            total_failures: ($failure | tonumber),
            success_rate: (if ($success | tonumber) + ($failure | tonumber) > 0 then (($success | tonumber) / (($success | tonumber) + ($failure | tonumber)) * 100 | floor) else 0 end)
        }'
}

# Cleanup old history (older than 30 days)
cleanup_old() {
    find "$HISTORY_DIR" -name "*.json" -mtime +30 -delete 2>/dev/null || true
    echo '{"status":"cleaned","retention_days":30}'
}

# Main
case "$MODE" in
    record)
        if [ -z "$COMMAND" ]; then
            echo '{"error":"missing command"}' >&2
            exit 1
        fi
        if [ -z "$SUCCESS" ]; then
            echo '{"error":"missing success status"}' >&2
            exit 1
        fi
        record_command "$COMMAND" "$SUCCESS"
        ;;
    check)
        if [ -z "$COMMAND" ]; then
            echo '{"error":"missing command"}' >&2
            exit 1
        fi
        check_command "$COMMAND"
        ;;
    stats)
        session_stats
        ;;
    cleanup)
        cleanup_old
        ;;
    *)
        echo '{"error":"invalid mode"}' >&2
        exit 1
        ;;
esac
