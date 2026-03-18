#!/bin/bash
set -euo pipefail
# read-sprint-state.sh
# Reads cached sprint state to avoid redundant GitHub API calls
#
# Usage: ./scripts/read-sprint-state.sh [KEY]
#
# Examples:
#   ./scripts/read-sprint-state.sh                    # Full state JSON
#   ./scripts/read-sprint-state.sh issue.number       # Just issue number
#   ./scripts/read-sprint-state.sh issue.labels       # Issue labels array
#   ./scripts/read-sprint-state.sh pr.exists          # Boolean PR exists
#   ./scripts/read-sprint-state.sh dependencies       # Dependencies object
#
# If cache doesn't exist, outputs empty JSON {} and exits with code 1
#
# Container Support:
#   - Checks SPRINT_STATE_FILE env var first (set by container-entrypoint.sh)
#   - Falls back to repo root .sprint-state.json
#   - Falls back to /tmp/.sprint-state.json (container without repo)

set -e

KEY="${1:-}"

# Determine sprint state file location
# Priority: 1) SPRINT_STATE_FILE env var, 2) repo root, 3) /tmp
find_sprint_state_file() {
  # Check environment variable first (container mode)
  if [ -n "$SPRINT_STATE_FILE" ] && [ -f "$SPRINT_STATE_FILE" ]; then
    echo "$SPRINT_STATE_FILE"
    return 0
  fi

  # Check repo root
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$toplevel" ] && [ -f "$toplevel/.state/.sprint-state.json" ]; then
    echo "$toplevel/.state/.sprint-state.json"
    return 0
  fi

  # Check /tmp (container fallback)
  if [ -f "/tmp/.sprint-state.json" ]; then
    echo "/tmp/.sprint-state.json"
    return 0
  fi

  # Check current directory as last resort
  if [ -f ".sprint-state.json" ]; then
    echo ".sprint-state.json"
    return 0
  fi

  return 1
}

SPRINT_STATE_FILE=$(find_sprint_state_file) || {
  echo '{}'
  exit 1
}

# Check if cache is stale (older than 1 hour)
CACHE_AGE=$(($(date +%s) - $(stat -f %m "$SPRINT_STATE_FILE" 2>/dev/null || stat -c %Y "$SPRINT_STATE_FILE" 2>/dev/null || echo 0)))
if [ "$CACHE_AGE" -gt 3600 ]; then
  echo '{"warning": "cache_stale", "age_seconds": '"$CACHE_AGE"'}' >&2
fi

# Read and optionally filter by key
if [ -z "$KEY" ]; then
  cat "$SPRINT_STATE_FILE"
else
  # Handle values including booleans and nulls
  RESULT=$(jq ".$KEY" "$SPRINT_STATE_FILE" 2>/dev/null)
  if [ -z "$RESULT" ] || [ "$RESULT" = "null" ]; then
    echo "null"
  else
    echo "$RESULT"
  fi
fi
