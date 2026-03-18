#!/bin/bash
set -euo pipefail
# structured-logging.sh
# Structured JSON logging library for container operations
# Part of Issue #510: Structured logging and metrics collection
#
# Provides consistent JSON-formatted logging for all container operations,
# enabling programmatic parsing, metrics extraction, and monitoring integration.
#
# Log Format:
#   {"ts":"2026-01-30T12:00:00Z","level":"INFO","event":"phase_start","context":{...},"message":"..."}
#
# Log Files:
#   /tmp/container.log      - Main structured log (JSON lines)
#   /tmp/progress.jsonl     - Progress events for monitoring
#   /tmp/metrics.json       - Aggregated metrics
#
# Usage:
#   source /path/to/structured-logging.sh
#   init_structured_logging
#   log_event "INFO" "phase_start" '{"phase":"implement"}' "Starting implementation phase"
#   finalize_metrics

# Prevent double-sourcing
if [ -n "${_STRUCTURED_LOGGING_SH_LOADED:-}" ]; then
  return 0
fi
readonly _STRUCTURED_LOGGING_SH_LOADED=1

# Log file locations
STRUCTURED_LOG_FILE="${STRUCTURED_LOG_FILE:-/tmp/container.log}"
PROGRESS_LOG_FILE="${PROGRESS_LOG_FILE:-/tmp/progress.jsonl}"
METRICS_FILE="${METRICS_FILE:-/tmp/metrics.json}"

# Maximum log size before truncation (10MB default)
STRUCTURED_LOG_MAX_SIZE="${STRUCTURED_LOG_MAX_SIZE:-10485760}"

# Maximum number of log lines to keep when truncating
STRUCTURED_LOG_MAX_LINES="${STRUCTURED_LOG_MAX_LINES:-10000}"

# Metrics tracking
declare -A _PHASE_START_TIMES
declare -A _PHASE_DURATIONS
declare -A _PHASE_STATUS
_FILES_WRITTEN=0
_COMMITS_MADE=0
_ERRORS_COUNT=0
_SESSION_START_TIME=""

# ============================================================
# Core Logging Functions
# ============================================================

# Initialize structured logging system
# Sets up log files and initializes metrics tracking
init_structured_logging() {
    # Create log directory if needed
    local log_dir
    log_dir="$(dirname "$STRUCTURED_LOG_FILE")"
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi

    # Initialize log files (truncate if exists)
    : > "$STRUCTURED_LOG_FILE"
    : > "$PROGRESS_LOG_FILE"

    # Record session start time
    _SESSION_START_TIME=$(date +%s)

    # Log initialization
    log_event "INFO" "session_start" '{}' "Container logging session started"
}

# Get current timestamp in ISO 8601 format
get_log_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Escape JSON string (basic escaping for message field)
escape_json() {
    local str="$1"
    # Escape backslashes, quotes, newlines, tabs
    echo "$str" | sed 's/\\/\\\\/g; s/"/\\"/g; s/'"$(printf '\t')"'/\\t/g' | tr '\n' ' '
}

# Log a structured event
# Arguments:
#   $1 - level (INFO, WARN, ERROR)
#   $2 - event type (phase_start, file_write, git_commit, error, etc.)
#   $3 - context (JSON object as string)
#   $4 - human-readable message
log_event() {
    local level="$1"
    local event="$2"
    local context="${3:-{}}"
    local message="$4"

    # Validate level
    case "$level" in
        INFO|WARN|ERROR|DEBUG) ;;
        *) level="INFO" ;;
    esac

    local timestamp
    timestamp=$(get_log_timestamp)

    # Escape message for JSON
    local escaped_msg
    escaped_msg=$(escape_json "$message")

    # Validate context is valid JSON, otherwise use empty object
    if ! echo "$context" | jq empty 2>/dev/null; then
        context='{}'
    fi

    # Build log entry using jq for proper JSON formatting
    local log_entry
    log_entry=$(jq -n \
        --arg ts "$timestamp" \
        --arg level "$level" \
        --arg event "$event" \
        --argjson context "$context" \
        --arg message "$escaped_msg" \
        '{ts: $ts, level: $level, event: $event, context: $context, message: $message}')

    # Write to main log
    echo "$log_entry" >> "$STRUCTURED_LOG_FILE"

    # Optionally write to progress log for monitoring-relevant events
    case "$event" in
        phase_start|phase_complete|phase_error|file_write|git_commit|pr_created)
            echo "$log_entry" >> "$PROGRESS_LOG_FILE"
            ;;
    esac

    # Track errors
    if [ "$level" = "ERROR" ]; then
        _ERRORS_COUNT=$((_ERRORS_COUNT + 1))
    fi

    # Check and rotate logs if needed
    rotate_logs_if_needed
}

# Convenience logging functions
log_info() {
    local event="$1"
    local context="${2:-{}}"
    local message="${3:-}"
    log_event "INFO" "$event" "$context" "$message"
}

log_warn() {
    local event="$1"
    local context="${2:-{}}"
    local message="${3:-}"
    log_event "WARN" "$event" "$context" "$message"
}

log_error() {
    local event="$1"
    local context="${2:-{}}"
    local message="${3:-}"
    log_event "ERROR" "$event" "$context" "$message"
}

log_debug() {
    if [ -n "${DEBUG:-}" ]; then
        local event="$1"
        local context="${2:-{}}"
        local message="${3:-}"
        log_event "DEBUG" "$event" "$context" "$message"
    fi
}

# ============================================================
# Phase Tracking Functions
# ============================================================

# Start tracking a phase
# Arguments:
#   $1 - phase name (spec, implement, test, etc.)
phase_start() {
    local phase="$1"
    local start_time
    start_time=$(date +%s)

    _PHASE_START_TIMES[$phase]=$start_time
    _PHASE_STATUS[$phase]="in_progress"

    local context
    context=$(jq -n --arg phase "$phase" '{phase: $phase}')
    log_info "phase_start" "$context" "Starting phase: $phase"
}

# Complete a phase
# Arguments:
#   $1 - phase name
#   $2 - status (complete, error, skipped)
phase_complete() {
    local phase="$1"
    local status="${2:-complete}"
    local end_time
    end_time=$(date +%s)

    local duration_ms=0
    if [ -n "${_PHASE_START_TIMES[$phase]:-}" ]; then
        local duration_s=$((end_time - _PHASE_START_TIMES[$phase]))
        duration_ms=$((duration_s * 1000))
    fi

    _PHASE_DURATIONS[$phase]=$duration_ms
    _PHASE_STATUS[$phase]=$status

    local context
    context=$(jq -n \
        --arg phase "$phase" \
        --arg status "$status" \
        --arg duration_ms "$duration_ms" \
        '{phase: $phase, status: $status, duration_ms: ($duration_ms | tonumber)}')

    local level="INFO"
    [ "$status" = "error" ] && level="ERROR"

    log_event "$level" "phase_complete" "$context" "Completed phase: $phase (${duration_ms}ms)"
}

# Log phase error
# Arguments:
#   $1 - phase name
#   $2 - error message
phase_error() {
    local phase="$1"
    local error_msg="$2"

    _PHASE_STATUS[$phase]="error"

    local context
    context=$(jq -n \
        --arg phase "$phase" \
        --arg error "$error_msg" \
        '{phase: $phase, error: $error}')

    log_error "phase_error" "$context" "Phase error in $phase: $error_msg"
}

# ============================================================
# Operation Tracking Functions
# ============================================================

# Log file write operation
# Arguments:
#   $1 - file path
#   $2 - operation (create, edit, delete)
log_file_write() {
    local file="$1"
    local operation="${2:-edit}"

    _FILES_WRITTEN=$((_FILES_WRITTEN + 1))

    local context
    context=$(jq -n \
        --arg file "$file" \
        --arg operation "$operation" \
        '{file: $file, operation: $operation}')

    log_info "file_write" "$context" "File ${operation}: $file"
}

# Log git commit
# Arguments:
#   $1 - commit SHA
#   $2 - commit message (first line)
log_git_commit() {
    local commit_sha="$1"
    local commit_msg="${2:-}"

    _COMMITS_MADE=$((_COMMITS_MADE + 1))

    # Truncate message to 100 chars
    commit_msg="${commit_msg:0:100}"

    local context
    context=$(jq -n \
        --arg sha "$commit_sha" \
        --arg message "$commit_msg" \
        '{commit_sha: $sha, message: $message}')

    log_info "git_commit" "$context" "Git commit: $commit_sha"
}

# Log PR creation
# Arguments:
#   $1 - PR number
#   $2 - PR URL
log_pr_created() {
    local pr_number="$1"
    local pr_url="$2"

    local context
    context=$(jq -n \
        --arg number "$pr_number" \
        --arg url "$pr_url" \
        '{pr_number: ($number | tonumber), pr_url: $url}')

    log_info "pr_created" "$context" "Pull request created: #$pr_number"
}

# Log test execution
# Arguments:
#   $1 - test command
#   $2 - exit code
#   $3 - duration in milliseconds
log_test_execution() {
    local test_cmd="$1"
    local exit_code="$2"
    local duration_ms="${3:-0}"

    local status="pass"
    [ "$exit_code" != "0" ] && status="fail"

    local context
    context=$(jq -n \
        --arg command "$test_cmd" \
        --arg status "$status" \
        --arg exit_code "$exit_code" \
        --arg duration_ms "$duration_ms" \
        '{command: $command, status: $status, exit_code: ($exit_code | tonumber), duration_ms: ($duration_ms | tonumber)}')

    local level="INFO"
    [ "$status" = "fail" ] && level="ERROR"

    log_event "$level" "test_execution" "$context" "Test ${status}: $test_cmd"
}

# ============================================================
# Metrics Collection
# ============================================================

# Generate and write metrics to file
# Called at end of container session
finalize_metrics() {
    local session_end_time
    session_end_time=$(date +%s)

    local total_duration_ms=0
    if [ -n "$_SESSION_START_TIME" ]; then
        local duration_s=$((session_end_time - _SESSION_START_TIME))
        total_duration_ms=$((duration_s * 1000))
    fi

    # Build phases object
    local phases_json="{"
    local first=true
    for phase in "${!_PHASE_STATUS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            phases_json+=","
        fi

        local status="${_PHASE_STATUS[$phase]}"
        local duration="${_PHASE_DURATIONS[$phase]:-0}"

        phases_json+="\"$phase\":{\"duration_ms\":$duration,\"status\":\"$status\"}"
    done
    phases_json+="}"

    # Build metrics JSON
    local metrics
    metrics=$(jq -n \
        --arg started_at "$(date -u -d @${_SESSION_START_TIME} '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r ${_SESSION_START_TIME} '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg completed_at "$(get_log_timestamp)" \
        --arg total_duration_ms "$total_duration_ms" \
        --argjson phases "$phases_json" \
        --arg files_written "$_FILES_WRITTEN" \
        --arg commits "$_COMMITS_MADE" \
        --arg errors "$_ERRORS_COUNT" \
        '{
            started_at: $started_at,
            completed_at: $completed_at,
            total_duration_ms: ($total_duration_ms | tonumber),
            phases: $phases,
            files_written: ($files_written | tonumber),
            commits: ($commits | tonumber),
            errors: ($errors | tonumber)
        }')

    # Write to metrics file
    echo "$metrics" > "$METRICS_FILE"

    log_info "metrics_finalized" '{}' "Metrics written to $METRICS_FILE"
}

# ============================================================
# Log Rotation and Truncation
# ============================================================

# Check log size and rotate if needed
rotate_logs_if_needed() {
    if [ ! -f "$STRUCTURED_LOG_FILE" ]; then
        return 0
    fi

    local file_size
    file_size=$(stat -f%z "$STRUCTURED_LOG_FILE" 2>/dev/null || stat -c%s "$STRUCTURED_LOG_FILE" 2>/dev/null || echo "0")

    if [ "$file_size" -ge "$STRUCTURED_LOG_MAX_SIZE" ]; then
        truncate_logs
    fi
}

# Truncate logs to keep only the most recent entries
truncate_logs() {
    if [ ! -f "$STRUCTURED_LOG_FILE" ]; then
        return 0
    fi

    # Keep last N lines
    local temp_file="${STRUCTURED_LOG_FILE}.tmp"
    tail -n "$STRUCTURED_LOG_MAX_LINES" "$STRUCTURED_LOG_FILE" > "$temp_file"
    mv "$temp_file" "$STRUCTURED_LOG_FILE"

    log_info "log_truncated" "{\"max_lines\":$STRUCTURED_LOG_MAX_LINES}" "Log file truncated to $STRUCTURED_LOG_MAX_LINES lines"
}

# ============================================================
# Cleanup and Export
# ============================================================

# Cleanup function to finalize metrics on exit
cleanup_structured_logging() {
    finalize_metrics
    log_info "session_end" '{}' "Container logging session ended"
}

# Set trap for automatic cleanup (can be disabled if already trapped)
if [ "${STRUCTURED_LOGGING_AUTO_CLEANUP:-true}" = "true" ]; then
    trap cleanup_structured_logging EXIT
fi

# Export functions for use in other scripts
export -f init_structured_logging get_log_timestamp escape_json
export -f log_event log_info log_warn log_error log_debug
export -f phase_start phase_complete phase_error
export -f log_file_write log_git_commit log_pr_created log_test_execution
export -f finalize_metrics rotate_logs_if_needed truncate_logs
export -f cleanup_structured_logging

# Export variables
export STRUCTURED_LOG_FILE PROGRESS_LOG_FILE METRICS_FILE
export STRUCTURED_LOG_MAX_SIZE STRUCTURED_LOG_MAX_LINES
