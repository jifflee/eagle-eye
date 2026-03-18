#!/bin/bash
set -euo pipefail
# issues-heartbeat.sh
# Updates heartbeat for active issue locks
#
# Usage:
#   ./scripts/issues-heartbeat.sh <issue_number>  # Update specific issue
#   ./scripts/issues-heartbeat.sh --all           # Update all locks
#
# Called automatically during active work to maintain lock liveness

set -e

ISSUE_NUMBER=""
ALL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --all)
      ALL=true
      shift
      ;;
    *)
      ISSUE_NUMBER="$1"
      shift
      ;;
  esac
done

LOCKS_FILE=".claude-locks.json"
CURRENT_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Exit silently if no locks file
if [ ! -f "$LOCKS_FILE" ]; then
  exit 0
fi

# Get current user and machine (stable identifiers)
CURRENT_USER="${USER:-$(whoami)}"
CURRENT_MACHINE="${HOSTNAME:-$(hostname)}"
# Remove any trailing domain from hostname
CURRENT_MACHINE="${CURRENT_MACHINE%%.*}"

# Function to update heartbeat for a specific issue
update_issue_heartbeat() {
  local issue_num="$1"

  # Update heartbeat timestamp for matching lock
  jq --arg issue "$issue_num" \
     --arg time "$CURRENT_TIME" \
     --arg user "$CURRENT_USER" \
     --arg machine "$CURRENT_MACHINE" \
     '(.locks[] | select(.issue == ($issue | tonumber))) |=
       (. + {last_heartbeat: $time} +
       (if .user then {user: .user} else {user: $user} end) +
       (if .machine then {machine: .machine} else {machine: $machine} end))' \
     "$LOCKS_FILE" > "${LOCKS_FILE}.tmp" && mv "${LOCKS_FILE}.tmp" "$LOCKS_FILE"
}

# Function to update all heartbeats
update_all_heartbeats() {
  jq --arg time "$CURRENT_TIME" \
     --arg user "$CURRENT_USER" \
     --arg machine "$CURRENT_MACHINE" \
     '.locks |= map(
       . + {last_heartbeat: $time} +
       (if .user then {user: .user} else {user: $user} end) +
       (if .machine then {machine: .machine} else {machine: $machine} end)
     )' \
     "$LOCKS_FILE" > "${LOCKS_FILE}.tmp" && mv "${LOCKS_FILE}.tmp" "$LOCKS_FILE"
}

# Main execution
if [ "$ALL" = true ]; then
  update_all_heartbeats
elif [ -n "$ISSUE_NUMBER" ]; then
  update_issue_heartbeat "$ISSUE_NUMBER"
else
  # If no args, update all (default behavior)
  update_all_heartbeats
fi
