#!/bin/bash
set -euo pipefail
# container-audit.sh
# Audit logging library for containerized workflows
# Part of Phase 9: Audit logging (Issue #142)
#
# Provides consistent logging functions for container lifecycle events.
# Used by container-launch.sh (host-side) and container-entrypoint.sh (container-side).
#
# Log format: timestamp|container_id|issue|event|details|outcome
#
# Usage:
#   source /path/to/container-audit.sh
#   audit_log "CONTAINER_START" "image=claude-base:latest" "success"

# Log location
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-${HOME}/.claude-tastic/logs}"
AUDIT_LOG_FILE="${AUDIT_LOG_DIR}/container-operations.log"

# Maximum log size before rotation (10MB)
AUDIT_LOG_MAX_SIZE=${AUDIT_LOG_MAX_SIZE:-10485760}

# Number of rotated logs to keep
AUDIT_LOG_KEEP_COUNT=${AUDIT_LOG_KEEP_COUNT:-5}

# Ensure log directory exists
ensure_audit_log_dir() {
    if [ ! -d "$AUDIT_LOG_DIR" ]; then
        mkdir -p "$AUDIT_LOG_DIR"
    fi
}

# Generate a short container ID if not provided
# Uses first 12 chars of hostname or generates random
generate_container_id() {
    if [ -n "$CONTAINER_ID" ]; then
        echo "$CONTAINER_ID"
    elif [ -n "$HOSTNAME" ]; then
        echo "${HOSTNAME:0:12}"
    else
        # Generate random ID
        head -c 6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 12
    fi
}

# Get current timestamp in ISO 8601 format
get_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Rotate logs if they exceed max size
rotate_logs_if_needed() {
    if [ ! -f "$AUDIT_LOG_FILE" ]; then
        return 0
    fi

    local file_size
    file_size=$(stat -f%z "$AUDIT_LOG_FILE" 2>/dev/null || stat -c%s "$AUDIT_LOG_FILE" 2>/dev/null || echo "0")

    if [ "$file_size" -ge "$AUDIT_LOG_MAX_SIZE" ]; then
        rotate_logs
    fi
}

# Rotate log files
rotate_logs() {
    local i

    # Remove oldest log if at limit
    if [ -f "${AUDIT_LOG_FILE}.${AUDIT_LOG_KEEP_COUNT}" ]; then
        rm -f "${AUDIT_LOG_FILE}.${AUDIT_LOG_KEEP_COUNT}"
    fi

    # Rotate existing logs
    for ((i = AUDIT_LOG_KEEP_COUNT - 1; i >= 1; i--)); do
        if [ -f "${AUDIT_LOG_FILE}.${i}" ]; then
            mv "${AUDIT_LOG_FILE}.${i}" "${AUDIT_LOG_FILE}.$((i + 1))"
        fi
    done

    # Move current to .1
    if [ -f "$AUDIT_LOG_FILE" ]; then
        mv "$AUDIT_LOG_FILE" "${AUDIT_LOG_FILE}.1"
    fi
}

# Main audit logging function
# Arguments:
#   $1 - event type (CONTAINER_START, CONTAINER_CLONE, etc.)
#   $2 - details (key=value pairs, comma-separated)
#   $3 - outcome (success, failed, error)
#   $4 - (optional) override container_id
#   $5 - (optional) override issue number
audit_log() {
    local event="$1"
    local details="${2:-}"
    local outcome="${3:-success}"
    local container_id="${4:-$(generate_container_id)}"
    local issue="${5:-${ISSUE:-unknown}}"

    # Validate event type
    case "$event" in
        CONTAINER_START|CONTAINER_CLONE|CONTAINER_BRANCH|CONTAINER_COMMIT|\
        CONTAINER_PUSH|CONTAINER_PR|CONTAINER_STOP|CONTAINER_ERROR|\
        CONTAINER_CLEANUP|CONTAINER_ORPHAN|\
        PERMISSION_GRANTED|PERMISSION_DENIED|PERMISSION_GUARDRAIL|\
        GUARDRAIL_PASSED|GUARDRAIL_FAILED|PERMISSION_PROMPT)
            ;;
        *)
            echo "[AUDIT_WARN] Unknown event type: $event" >&2
            ;;
    esac

    ensure_audit_log_dir
    rotate_logs_if_needed

    local timestamp
    timestamp=$(get_timestamp)

    # Escape pipe characters in details
    details=$(echo "$details" | tr '|' ';')

    local log_line="${timestamp}|${container_id}|${issue}|${event}|${details}|${outcome}"

    # Write to log file
    echo "$log_line" >> "$AUDIT_LOG_FILE"

    # Also output to stderr for visibility during execution
    if [ "${AUDIT_LOG_VERBOSE:-false}" = "true" ]; then
        echo "[AUDIT] $log_line" >&2
    fi
}

# Convenience functions for specific events
audit_container_start() {
    local image="$1"
    local tokens_present="${2:-false}"
    local extra="${3:-}"
    local details="image=${image},tokens_present=${tokens_present}"
    [ -n "$extra" ] && details="${details},${extra}"
    audit_log "CONTAINER_START" "$details" "success"
}

audit_container_clone() {
    local repo="$1"
    local branch="$2"
    local commit_sha="${3:-}"
    local details="repo=${repo},branch=${branch}"
    [ -n "$commit_sha" ] && details="${details},commit_sha=${commit_sha}"
    audit_log "CONTAINER_CLONE" "$details" "success"
}

audit_container_branch() {
    local branch_name="$1"
    audit_log "CONTAINER_BRANCH" "branch_name=${branch_name}" "success"
}

audit_container_commit() {
    local commit_sha="$1"
    local message_preview="${2:-}"
    # Truncate message preview to 50 chars and escape special chars
    message_preview=$(echo "${message_preview:0:50}" | tr '|,\n' ' ')
    local details="commit_sha=${commit_sha}"
    [ -n "$message_preview" ] && details="${details},message=${message_preview}"
    audit_log "CONTAINER_COMMIT" "$details" "success"
}

audit_container_push() {
    local branch="$1"
    local commit_count="${2:-1}"
    audit_log "CONTAINER_PUSH" "branch=${branch},commit_count=${commit_count}" "success"
}

audit_container_pr() {
    local pr_number="$1"
    local pr_url="${2:-}"
    local details="pr_number=${pr_number}"
    [ -n "$pr_url" ] && details="${details},pr_url=${pr_url}"
    audit_log "CONTAINER_PR" "$details" "success"
}

audit_container_stop() {
    local exit_code="$1"
    local duration="${2:-}"
    local details="exit_code=${exit_code}"
    [ -n "$duration" ] && details="${details},duration=${duration}"
    local outcome="success"
    [ "$exit_code" != "0" ] && outcome="failed"
    audit_log "CONTAINER_STOP" "$details" "$outcome"
}

audit_container_error() {
    local error_type="$1"
    local message="${2:-}"
    # Truncate message to 200 chars and escape special chars
    message=$(echo "${message:0:200}" | tr '|,\n' ' ')
    local details="error_type=${error_type}"
    [ -n "$message" ] && details="${details},message=${message}"
    audit_log "CONTAINER_ERROR" "$details" "error"
}

# Permission audit convenience functions (Issue #153)
audit_permission_granted() {
    local category="$1"
    local operation="$2"
    local reason="${3:-auto_allow}"
    audit_log "PERMISSION_GRANTED" "category=${category},operation=${operation},reason=${reason}" "success"
}

audit_permission_denied() {
    local category="$1"
    local operation="$2"
    local reason="$3"
    audit_log "PERMISSION_DENIED" "category=${category},operation=${operation},reason=${reason}" "denied"
}

audit_permission_guardrail() {
    local category="$1"
    local operation="$2"
    local guardrail="$3"
    audit_log "PERMISSION_GUARDRAIL" "category=${category},operation=${operation},guardrail=${guardrail}" "pending"
}

audit_guardrail_passed() {
    local guardrail="$1"
    local operation="$2"
    local validation_result="${3:-}"
    local details="guardrail=${guardrail},operation=${operation}"
    [ -n "$validation_result" ] && details="${details},result=${validation_result}"
    audit_log "GUARDRAIL_PASSED" "$details" "success"
}

audit_guardrail_failed() {
    local guardrail="$1"
    local operation="$2"
    local reason="$3"
    audit_log "GUARDRAIL_FAILED" "guardrail=${guardrail},operation=${operation},reason=${reason}" "failed"
}

audit_permission_prompt() {
    local category="$1"
    local operation="$2"
    local user_response="${3:-pending}"
    audit_log "PERMISSION_PROMPT" "category=${category},operation=${operation},response=${user_response}" "prompt"
}

# Track container start time for duration calculation
_container_start_time=""

start_duration_timer() {
    _container_start_time=$(date +%s)
}

get_duration() {
    if [ -z "$_container_start_time" ]; then
        echo "unknown"
        return
    fi
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - _container_start_time))
    echo "${duration}s"
}

# Export functions if this script is sourced
export -f audit_log ensure_audit_log_dir generate_container_id get_timestamp
export -f rotate_logs_if_needed rotate_logs
export -f audit_container_start audit_container_clone audit_container_branch
export -f audit_container_commit audit_container_push audit_container_pr
export -f audit_container_stop audit_container_error
export -f audit_permission_granted audit_permission_denied audit_permission_guardrail
export -f audit_guardrail_passed audit_guardrail_failed audit_permission_prompt
export -f start_duration_timer get_duration
export AUDIT_LOG_DIR AUDIT_LOG_FILE AUDIT_LOG_MAX_SIZE AUDIT_LOG_KEEP_COUNT
