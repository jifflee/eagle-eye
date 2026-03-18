#!/bin/bash
set -euo pipefail
# container-progress.sh
# Progress logging functions for container observability (Issue #508)
#
# This script provides functions to log structured progress events during
# sprint-work execution. Events are written to a JSONL file for monitoring.
#
# Event types:
#   - phase_start/phase_end: SDLC phase transitions
#   - file_write/file_delete: File operations
#   - git_commit/git_push: Git operations
#   - claude_start/claude_end: Claude invocations
#   - error: Errors and failures
#
# Usage:
#   source scripts/container-progress.sh
#   log_progress phase_start "implement"
#   log_progress file_write "src/main.py"
#   log_progress git_commit "abc123"
#
# Or as standalone:
#   ./scripts/container-progress.sh phase_start implement
#
# Environment Variables:
#   PROGRESS_LOG          Path to progress log (default: /tmp/progress.jsonl)
#   HEARTBEAT_FILE        Path to heartbeat file (default: /tmp/heartbeat)

# Configuration
PROGRESS_LOG="${PROGRESS_LOG:-/tmp/progress.jsonl}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-/tmp/heartbeat}"
HEARTBEAT_STATE="/tmp/heartbeat-state"

# Current phase tracking
_CURRENT_PHASE="${_CURRENT_PHASE:-}"

# Initialize progress log
init_progress_log() {
    if [ ! -f "$PROGRESS_LOG" ]; then
        local entry
        entry=$(jq -n \
            --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --arg issue "${ISSUE:-unknown}" \
            '{ts: $ts, event: "init", issue: $issue}')
        echo "$entry" > "$PROGRESS_LOG"
    fi
}

# Log a progress event
log_progress() {
    local event_type="$1"
    local detail="$2"
    local extra="${3:-}"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build JSON entry
    local entry
    case "$event_type" in
        phase_start)
            _CURRENT_PHASE="$detail"
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg phase "$detail" \
                '{ts: $ts, event: "phase_start", phase: $phase}')

            # Update heartbeat state
            update_heartbeat_state "$detail" "starting phase"
            ;;

        phase_end)
            local duration="${extra:-0}"
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg phase "$detail" \
                --argjson duration "$duration" \
                '{ts: $ts, event: "phase_end", phase: $phase, duration_ms: $duration}')
            _CURRENT_PHASE=""
            ;;

        file_write)
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg path "$detail" \
                --arg phase "${_CURRENT_PHASE:-unknown}" \
                '{ts: $ts, event: "file_write", path: $path, phase: $phase}')

            update_heartbeat_state "$_CURRENT_PHASE" "writing $detail"
            ;;

        file_delete)
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg path "$detail" \
                --arg phase "${_CURRENT_PHASE:-unknown}" \
                '{ts: $ts, event: "file_delete", path: $path, phase: $phase}')
            ;;

        git_commit)
            local sha="$detail"
            local message="${extra:-}"
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg sha "$sha" \
                --arg message "$message" \
                '{ts: $ts, event: "git_commit", sha: $sha, message: $message}')

            update_heartbeat_state "$_CURRENT_PHASE" "committed $sha"
            ;;

        git_push)
            local branch="$detail"
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg branch "$branch" \
                '{ts: $ts, event: "git_push", branch: $branch}')

            update_heartbeat_state "$_CURRENT_PHASE" "pushed to $branch"
            ;;

        claude_start)
            local prompt_length="${extra:-0}"
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg mode "$detail" \
                --argjson prompt_length "$prompt_length" \
                '{ts: $ts, event: "claude_start", mode: $mode, prompt_length: $prompt_length}')

            update_heartbeat_state "claude" "invoking claude ($detail)"
            ;;

        claude_end)
            local exit_code="$detail"
            local duration="${extra:-0}"
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --argjson exit_code "$exit_code" \
                --argjson duration "$duration" \
                '{ts: $ts, event: "claude_end", exit_code: $exit_code, duration_ms: $duration}')
            ;;

        pr_created)
            local pr_url="$detail"
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg url "$pr_url" \
                '{ts: $ts, event: "pr_created", url: $url}')

            update_heartbeat_state "pr" "PR created"
            ;;

        error)
            local message="$detail"
            local context="${extra:-}"
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg message "$message" \
                --arg context "$context" \
                --arg phase "${_CURRENT_PHASE:-unknown}" \
                '{ts: $ts, event: "error", message: $message, context: $context, phase: $phase}')
            ;;

        *)
            # Generic event
            entry=$(jq -n \
                --arg ts "$timestamp" \
                --arg event "$event_type" \
                --arg detail "$detail" \
                '{ts: $ts, event: $event, detail: $detail}')
            ;;
    esac

    # Append to progress log
    echo "$entry" >> "$PROGRESS_LOG"
}

# Update heartbeat state file
update_heartbeat_state() {
    local phase="$1"
    local action="$2"

    cat > "$HEARTBEAT_STATE" << EOF
phase=$phase
action=$action
EOF
}

# Get progress summary
get_progress_summary() {
    if [ ! -f "$PROGRESS_LOG" ]; then
        echo '{"error": "no progress log"}'
        return 1
    fi

    # Count events by type
    local summary
    summary=$(jq -s '
        {
            total_events: length,
            phases_started: [.[] | select(.event == "phase_start")] | length,
            phases_completed: [.[] | select(.event == "phase_end")] | length,
            files_written: [.[] | select(.event == "file_write")] | length,
            commits: [.[] | select(.event == "git_commit")] | length,
            errors: [.[] | select(.event == "error")] | length,
            last_event: (if length > 0 then .[-1] else null end)
        }
    ' "$PROGRESS_LOG" 2>/dev/null)

    echo "$summary"
}

# Get recent events (for monitoring display)
get_recent_events() {
    local count="${1:-10}"

    if [ ! -f "$PROGRESS_LOG" ]; then
        echo '[]'
        return
    fi

    tail -n "$count" "$PROGRESS_LOG" | jq -s '.'
}

# Get events by type
get_events_by_type() {
    local event_type="$1"

    if [ ! -f "$PROGRESS_LOG" ]; then
        echo '[]'
        return
    fi

    jq -s "[.[] | select(.event == \"$event_type\")]" "$PROGRESS_LOG"
}

# Check if progress log exists and has recent activity
check_progress_health() {
    if [ ! -f "$PROGRESS_LOG" ]; then
        echo '{"healthy": false, "reason": "no progress log"}'
        return 1
    fi

    local last_event
    last_event=$(tail -1 "$PROGRESS_LOG" 2>/dev/null)

    if [ -z "$last_event" ]; then
        echo '{"healthy": false, "reason": "empty progress log"}'
        return 1
    fi

    local last_ts
    last_ts=$(echo "$last_event" | jq -r '.ts' 2>/dev/null)

    if [ -z "$last_ts" ] || [ "$last_ts" = "null" ]; then
        echo '{"healthy": false, "reason": "invalid last event"}'
        return 1
    fi

    # Calculate age
    local now_epoch
    local last_epoch
    now_epoch=$(date +%s)
    last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" +%s 2>/dev/null || date -d "$last_ts" +%s 2>/dev/null || echo "0")

    local age=$((now_epoch - last_epoch))
    local healthy="true"
    local reason=""

    # Consider unhealthy if no activity for 5+ minutes
    if [ "$age" -gt 300 ]; then
        healthy="false"
        reason="no activity for ${age}s"
    fi

    jq -n \
        --argjson healthy "$healthy" \
        --arg reason "$reason" \
        --argjson age "$age" \
        --arg last_ts "$last_ts" \
        '{healthy: $healthy, reason: $reason, age_seconds: $age, last_activity: $last_ts}'
}

# Usage
usage() {
    cat << EOF
container-progress.sh - Progress logging for container observability

USAGE:
    $0 <event_type> <detail> [extra]

EVENT TYPES:
    phase_start <phase>         Phase started (e.g., implement, test)
    phase_end <phase> [duration_ms]  Phase completed
    file_write <path>           File written
    file_delete <path>          File deleted
    git_commit <sha> [message]  Git commit made
    git_push <branch>           Git push completed
    claude_start <mode> [prompt_length]  Claude invocation started
    claude_end <exit_code> [duration_ms] Claude invocation ended
    pr_created <url>            PR created
    error <message> [context]   Error occurred

COMMANDS:
    summary                     Get progress summary
    recent [count]              Get recent events (default: 10)
    events <type>               Get events by type
    health                      Check progress log health

EXAMPLES:
    # Log phase start
    $0 phase_start implement

    # Log file write
    $0 file_write src/main.py

    # Log Claude invocation
    $0 claude_start implementation 1500
    $0 claude_end 0 45000

    # Get summary
    $0 summary

SOURCING:
    source $0
    log_progress phase_start "implement"
    log_progress file_write "src/main.py"

EOF
}

# Main (when run as script, not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        summary)
            get_progress_summary
            ;;
        recent)
            get_recent_events "${2:-10}"
            ;;
        events)
            get_events_by_type "${2:-phase_start}"
            ;;
        health)
            check_progress_health
            ;;
        -h|--help)
            usage
            ;;
        "")
            usage
            exit 1
            ;;
        *)
            init_progress_log
            log_progress "$1" "${2:-}" "${3:-}"
            ;;
    esac
fi
