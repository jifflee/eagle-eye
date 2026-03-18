#!/bin/bash
set -euo pipefail
# update-work-state.sh
# Updates .claude/work-state.json after work completion
# Called by sprint-orchestrator.sh and other work completion points
#
# Usage: ./scripts/update-work-state.sh [OPTIONS]
#
# Options:
#   --start ISSUE         Mark work as started for issue number
#   --complete ISSUE      Mark work as completed for issue number
#   --result STATUS       Set result status: success|failure (default: success)
#   --duration SECONDS    Set duration in seconds
#   --json                Output resulting state as JSON
#   --help                Show this help message
#
# Examples:
#   ./scripts/update-work-state.sh --start 407
#   ./scripts/update-work-state.sh --complete 407 --result success --duration 300
#
# State file: .claude/work-state.json

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities if available
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
  source "${SCRIPT_DIR}/lib/common.sh"
else
  log_info() { echo "[INFO] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fi

# Default values
ACTION=""
ISSUE=""
RESULT="success"
DURATION=""
OUTPUT_JSON=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)
      ACTION="start"
      ISSUE="$2"
      shift 2
      ;;
    --complete)
      ACTION="complete"
      ISSUE="$2"
      shift 2
      ;;
    --result)
      RESULT="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 2
      ;;
  esac
done

# Validate action
if [ -z "$ACTION" ]; then
  log_error "Must specify --start or --complete"
  exit 2
fi

# Validate issue number
if [ -z "$ISSUE" ] || ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  log_error "Issue number must be a positive integer"
  exit 2
fi

# Find or create state file directory
find_state_dir() {
  # Check repo root
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$toplevel" ]; then
    echo "$toplevel/.claude"
    return 0
  fi

  # Fallback to current directory
  echo ".claude"
}

STATE_DIR=$(find_state_dir)
STATE_FILE="$STATE_DIR/work-state.json"

# Ensure directory exists
mkdir -p "$STATE_DIR"

# Initialize state file if it doesn't exist
if [ ! -f "$STATE_FILE" ]; then
  echo '{
  "version": "1.0",
  "last_updated": null,
  "work_in_progress": false,
  "last_work_issue": null,
  "last_work_result": null,
  "last_work_completed": null,
  "last_work_duration_seconds": null
}' > "$STATE_FILE"
fi

# Read current state
CURRENT_STATE=$(cat "$STATE_FILE")
NOW=$(timestamp)

# Update state based on action
case "$ACTION" in
  start)
    NEW_STATE=$(echo "$CURRENT_STATE" | jq \
      --arg ts "$NOW" \
      --argjson issue "$ISSUE" \
      '.last_updated = $ts | .work_in_progress = true | .current_issue = $issue')
    log_info "Marked work started for issue #$ISSUE"
    ;;
  complete)
    # Build update with optional duration
    if [ -n "$DURATION" ]; then
      NEW_STATE=$(echo "$CURRENT_STATE" | jq \
        --arg ts "$NOW" \
        --argjson issue "$ISSUE" \
        --arg result "$RESULT" \
        --argjson duration "$DURATION" \
        '.last_updated = $ts | .work_in_progress = false | .last_work_issue = $issue | .last_work_result = $result | .last_work_completed = $ts | .last_work_duration_seconds = $duration | del(.current_issue)')
    else
      NEW_STATE=$(echo "$CURRENT_STATE" | jq \
        --arg ts "$NOW" \
        --argjson issue "$ISSUE" \
        --arg result "$RESULT" \
        '.last_updated = $ts | .work_in_progress = false | .last_work_issue = $issue | .last_work_result = $result | .last_work_completed = $ts | del(.current_issue)')
    fi
    log_info "Marked work completed for issue #$ISSUE (result: $RESULT)"
    ;;
esac

# Write updated state
echo "$NEW_STATE" > "$STATE_FILE"

# Output JSON if requested
if [ "$OUTPUT_JSON" = true ]; then
  cat "$STATE_FILE"
fi
