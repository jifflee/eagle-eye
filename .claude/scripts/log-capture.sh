#!/usr/bin/env bash
# log-capture.sh - CLI session logging and error capture system
# Captures session activity, errors, and context for diagnostics

set -euo pipefail

# Configuration
LOG_DIR="${CLAUDE_AGENTS_HOME:-$HOME/.claude-agents}/logs"
SESSION_LOG_DIR="$LOG_DIR/sessions"
ERROR_LOG_DIR="$LOG_DIR/errors"
SNAPSHOT_LOG_DIR="$LOG_DIR/snapshots"
MAX_LOG_DAYS=7
MAX_LOG_SIZE_MB=100

# Ensure log directories exist
init_logging() {
    mkdir -p "$SESSION_LOG_DIR" "$ERROR_LOG_DIR" "$SNAPSHOT_LOG_DIR"
}

# Generate session ID
generate_session_id() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Fallback: timestamp + random
        echo "$(date +%s)-$(( RANDOM * RANDOM ))" | md5sum | cut -d' ' -f1 || echo "$(date +%s)-$$"
    fi
}

# Get current session ID or create new one
get_session_id() {
    local session_file="${TMPDIR:-/tmp}/.claude-session-id"
    if [[ -f "$session_file" ]]; then
        cat "$session_file"
    else
        local session_id
        session_id=$(generate_session_id)
        echo "$session_id" > "$session_file"
        echo "$session_id"
    fi
}

# Sanitize environment variables (remove secrets)
sanitize_env() {
    env | grep -v -E '(TOKEN|SECRET|KEY|PASSWORD|CREDENTIAL|AUTH)' || true
}

# Get git repository info
get_repo_info() {
    local repo=""
    local branch=""
    local worktree=""

    if git rev-parse --git-dir &> /dev/null; then
        repo=$(git config --get remote.origin.url 2>/dev/null || echo "unknown")
        # Clean up repo URL
        repo=$(echo "$repo" | sed -E 's#.*github\.com[:/]##' | sed 's#\.git$##')
        branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        worktree=$(pwd)
    fi

    # Return compact JSON for JSONL format
    jq -nc --arg repo "$repo" --arg branch "$branch" --arg worktree "$worktree" \
        '{repo: $repo, branch: $branch, worktree: $worktree}'
}

# Log session event
log_event() {
    local event_type="$1"
    shift
    local data="$*"

    init_logging

    local session_id
    session_id=$(get_session_id)
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local session_log="$SESSION_LOG_DIR/$(date +%Y-%m-%d)-session-$session_id.jsonl"
    local repo_info
    repo_info=$(get_repo_info)

    # Parse data - check if it's valid JSON or a string
    local data_json
    if echo "$data" | jq empty 2>/dev/null; then
        # Valid JSON - use as-is
        data_json="$data"
    else
        # Not valid JSON - treat as string and wrap in object
        data_json=$(jq -nc --arg str "$data" '{message: $str}')
    fi

    # Create JSON log entry using jq for proper formatting
    jq -nc \
        --arg session_id "$session_id" \
        --arg timestamp "$timestamp" \
        --arg event "$event_type" \
        --argjson repo_info "$repo_info" \
        --argjson data "$data_json" \
        '{session_id: $session_id, timestamp: $timestamp, event: $event, repo_info: $repo_info, data: $data}' \
        >> "$session_log"
}

# Capture error context
capture_error() {
    local command="$1"
    local exit_code="$2"
    local stderr="${3:-}"

    init_logging

    local session_id
    session_id=$(get_session_id)
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local error_id
    error_id=$(date +%s)
    local error_file="$ERROR_LOG_DIR/$(date +%Y-%m-%d)-error-$error_id.json"
    local snapshot_file="$SNAPSHOT_LOG_DIR/$(date +%Y-%m-%d)-snapshot-$error_id.json"

    # Capture context snapshot
    capture_snapshot "$snapshot_file"

    # Escape JSON strings
    local escaped_command
    escaped_command=$(echo "$command" | jq -Rs .)
    local escaped_stderr
    escaped_stderr=$(echo "$stderr" | jq -Rs .)

    local repo_info
    repo_info=$(get_repo_info)

    # Create error log entry
    cat <<EOF > "$error_file"
{
  "session_id": "$session_id",
  "timestamp": "$timestamp",
  "error_id": "$error_id",
  "repo_info": $repo_info,
  "command": $escaped_command,
  "exit_code": $exit_code,
  "stderr": $escaped_stderr,
  "snapshot": "$snapshot_file"
}
EOF

    # Also log to session log (compact JSON for JSONL format)
    log_event "command_failed" "$(jq -c '.' "$error_file")"

    echo "Error captured: $error_file" >&2
}

# Capture context snapshot
capture_snapshot() {
    local snapshot_file="$1"

    local git_status=""
    local git_branch=""
    local working_dir=""
    local worktree_list=""
    local env_vars=""

    # Capture git status
    if git rev-parse --git-dir &> /dev/null; then
        git_status=$(git status 2>&1 | jq -Rs . || echo '""')
        git_branch=$(git branch -vv 2>&1 | jq -Rs . || echo '""')
        worktree_list=$(git worktree list 2>&1 | jq -Rs . || echo '""')
    else
        git_status='""'
        git_branch='""'
        worktree_list='""'
    fi

    # Capture working directory listing
    working_dir=$(ls -la 2>&1 | jq -Rs . || echo '""')

    # Capture sanitized environment
    env_vars=$(sanitize_env | jq -Rs . || echo '""')

    # Create snapshot
    cat <<EOF > "$snapshot_file"
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "git_status": $git_status,
  "git_branch": $git_branch,
  "worktree_list": $worktree_list,
  "working_dir": $working_dir,
  "environment": $env_vars
}
EOF
}

# Log command execution
log_command() {
    local command="$1"
    local exit_code="${2:-0}"
    local stderr="${3:-}"

    if [[ "$exit_code" -ne 0 ]]; then
        capture_error "$command" "$exit_code" "$stderr"
    else
        local escaped_command
        escaped_command=$(echo "$command" | jq -Rs .)
        log_event "command_executed" "{\"command\":$escaped_command,\"exit_code\":$exit_code}"
    fi
}

# Start session logging
start_session() {
    local session_id
    session_id=$(get_session_id)
    local repo_info
    repo_info=$(get_repo_info)

    log_event "session_start" "{\"session_id\":\"$session_id\"}"
}

# End session logging
end_session() {
    log_event "session_end" "{}"
}

# Cleanup old logs
cleanup_logs() {
    init_logging

    # Remove logs older than MAX_LOG_DAYS
    find "$SESSION_LOG_DIR" -type f -mtime +$MAX_LOG_DAYS -delete 2>/dev/null || true
    find "$ERROR_LOG_DIR" -type f -mtime +$MAX_LOG_DAYS -delete 2>/dev/null || true
    find "$SNAPSHOT_LOG_DIR" -type f -mtime +$MAX_LOG_DAYS -delete 2>/dev/null || true

    # Check total size and remove oldest if over limit
    local total_size
    total_size=$(du -sm "$LOG_DIR" 2>/dev/null | cut -f1 || echo 0)

    if [[ $total_size -gt $MAX_LOG_SIZE_MB ]]; then
        # Remove oldest session logs
        find "$SESSION_LOG_DIR" -type f -printf '%T+ %p\n' | sort | head -n 10 | cut -d' ' -f2- | xargs rm -f 2>/dev/null || true
    fi
}

# Main command dispatcher
case "${1:-}" in
    init)
        init_logging
        ;;
    start-session)
        start_session
        ;;
    end-session)
        end_session
        ;;
    log-event)
        log_event "$2" "${3:-{}}"
        ;;
    log-command)
        log_command "$2" "${3:-0}" "${4:-}"
        ;;
    capture-error)
        capture_error "$2" "$3" "${4:-}"
        ;;
    capture-snapshot)
        capture_snapshot "${2:-$SNAPSHOT_LOG_DIR/snapshot-$(date +%s).json}"
        ;;
    cleanup)
        cleanup_logs
        ;;
    session-id)
        get_session_id
        ;;
    *)
        echo "Usage: $0 {init|start-session|end-session|log-event|log-command|capture-error|capture-snapshot|cleanup|session-id}" >&2
        exit 1
        ;;
esac
