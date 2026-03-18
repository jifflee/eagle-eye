#!/bin/bash
set -euo pipefail
# n8n-can-work.sh
# n8n integration: Check if Claude Code can accept new work
# Zero-token decision making (reads state file only, no API calls)
#
# Usage: ./scripts/n8n-can-work.sh [OPTIONS]
#
# Options:
#   --threshold-minutes N   Minimum minutes since last work (default: 5)
#   --json                  Output JSON only (suppress logging)
#   --help                  Show this help message
#
# Output (JSON):
# {
#   "can_trigger": true,
#   "reason": "capacity_available",
#   "work_in_progress": false,
#   "last_work_completed": "2026-01-25T15:00:00Z",
#   "minutes_since_last_work": 45
# }
#
# Exit codes:
#   0 - Success (can_trigger may be true or false)
#   1 - Error reading state
#   2 - Invalid arguments
#
# State file: .claude/work-state.json
# Updated by: post-work completion hook

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities if available
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
  source "${SCRIPT_DIR}/lib/common.sh"
else
  # Minimal fallback if common.sh not available
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fi

# Default configuration
THRESHOLD_MINUTES=5
JSON_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold-minutes)
      THRESHOLD_MINUTES="$2"
      shift 2
      ;;
    --json)
      JSON_ONLY=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Validate threshold is a number
if ! [[ "$THRESHOLD_MINUTES" =~ ^[0-9]+$ ]]; then
  echo '{"error": "invalid_threshold", "message": "threshold-minutes must be a positive integer"}'
  exit 2
fi

# Find work state file
# Priority: 1) WORK_STATE_FILE env var, 2) repo root .claude/, 3) /tmp/.claude/, 4) ./.claude/
find_work_state_file() {
  # Check environment variable first (container mode)
  if [ -n "${WORK_STATE_FILE:-}" ] && [ -f "$WORK_STATE_FILE" ]; then
    echo "$WORK_STATE_FILE"
    return 0
  fi

  # Check repo root
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$toplevel" ] && [ -f "$toplevel/.claude/work-state.json" ]; then
    echo "$toplevel/.claude/work-state.json"
    return 0
  fi

  # Check /tmp (container fallback)
  if [ -f "/tmp/.claude/work-state.json" ]; then
    echo "/tmp/.claude/work-state.json"
    return 0
  fi

  # Check current directory as last resort
  if [ -f ".claude/work-state.json" ]; then
    echo ".claude/work-state.json"
    return 0
  fi

  return 1
}

# Output JSON result
output_result() {
  local can_trigger="$1"
  local reason="$2"
  local work_in_progress="$3"
  local last_completed="$4"
  local minutes_since="$5"

  jq -n \
    --argjson can_trigger "$can_trigger" \
    --arg reason "$reason" \
    --argjson work_in_progress "$work_in_progress" \
    --arg last_work_completed "$last_completed" \
    --argjson minutes_since_last_work "$minutes_since" \
    --arg checked_at "$(timestamp)" \
    '{
      can_trigger: $can_trigger,
      reason: $reason,
      work_in_progress: $work_in_progress,
      last_work_completed: $last_work_completed,
      minutes_since_last_work: $minutes_since_last_work,
      checked_at: $checked_at
    }'
}

# Main logic
main() {
  # Try to find state file
  local state_file
  if ! state_file=$(find_work_state_file); then
    # No state file = no previous work = can trigger (fresh start)
    if [ "$JSON_ONLY" = false ]; then
      log_warn "No work state file found - assuming fresh start"
    fi
    output_result true "no_state_file" false "" 999999
    exit 0
  fi

  if [ "$JSON_ONLY" = false ]; then
    log_info "Reading state from: $state_file"
  fi

  # Read state file
  local state
  if ! state=$(cat "$state_file" 2>/dev/null); then
    output_result false "state_read_error" false "" 0
    exit 1
  fi

  # Extract values from state
  local work_in_progress last_completed last_result
  work_in_progress=$(echo "$state" | jq -r '.work_in_progress // false')
  last_completed=$(echo "$state" | jq -r '.last_work_completed // ""')
  last_result=$(echo "$state" | jq -r '.last_work_result // "unknown"')

  # Check if work is currently in progress
  if [ "$work_in_progress" = "true" ]; then
    output_result false "work_in_progress" true "$last_completed" 0
    exit 0
  fi

  # Calculate minutes since last work
  local minutes_since=999999
  if [ -n "$last_completed" ] && [ "$last_completed" != "null" ]; then
    # Convert ISO timestamp to epoch (UTC)
    local last_epoch now_epoch
    # Handle both GNU and BSD date
    if date --version >/dev/null 2>&1; then
      # GNU date - parse UTC timestamp
      last_epoch=$(date -u -d "$last_completed" +%s 2>/dev/null || echo 0)
    else
      # BSD date (macOS) - parse UTC timestamp
      # Note: -j uses input as-is, and the Z suffix indicates UTC
      last_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$last_completed" +%s 2>/dev/null || echo 0)
    fi
    # Get current time in UTC epoch
    now_epoch=$(date -u +%s)

    if [ "$last_epoch" -gt 0 ]; then
      minutes_since=$(( (now_epoch - last_epoch) / 60 ))
      # Ensure non-negative (handle clock skew edge cases)
      if [ "$minutes_since" -lt 0 ]; then
        minutes_since=0
      fi
    fi
  fi

  # Decision logic
  local can_trigger=true
  local reason="capacity_available"

  # Check threshold
  if [ "$minutes_since" -lt "$THRESHOLD_MINUTES" ]; then
    can_trigger=false
    reason="cooldown_period"
  fi

  # Check last result (optional: don't trigger immediately after failure)
  # Currently not blocking on failure, but logging for visibility
  if [ "$last_result" = "failure" ] && [ "$minutes_since" -lt 10 ]; then
    if [ "$JSON_ONLY" = false ]; then
      log_warn "Last work failed ${minutes_since}m ago"
    fi
  fi

  output_result "$can_trigger" "$reason" false "$last_completed" "$minutes_since"
}

# Run main
main
