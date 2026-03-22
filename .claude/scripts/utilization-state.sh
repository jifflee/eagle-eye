#!/bin/bash
set -euo pipefail
# utilization-state.sh
# Manage real-time utilization state for n8n orchestration
# Token-protective: Cache state, minimize API calls
#
# Usage:
#   ./scripts/utilization-state.sh --read                          # Read cached state (free)
#   ./scripts/utilization-state.sh --update --usage PCT --tokens N # Update state after work
#   ./scripts/utilization-state.sh --check-stale                   # Check if data is stale
#   ./scripts/utilization-state.sh --refresh                       # Force refresh (costs tokens)
#   ./scripts/utilization-state.sh --init                          # Initialize state file
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - State file not found (for --read)
#   3 - File write error

set -e

# Configuration
MAIN_REPO=$(git rev-parse --show-toplevel 2>/dev/null) || MAIN_REPO="."
STATE_DIR="${CLAUDE_STATE_DIR:-$MAIN_REPO/.claude}"
STATE_FILE="${CLAUDE_STATE_FILE:-$STATE_DIR/utilization-state.json}"
STALE_THRESHOLD_MINUTES="${CLAUDE_STALE_THRESHOLD:-60}"

# Ensure state directory exists
ensure_state_dir() {
  if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
  fi
}

# Get ISO 8601 timestamp in UTC
get_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Get epoch seconds
get_epoch_seconds() {
  date +%s
}

# Calculate minutes between two ISO timestamps
minutes_since() {
  local timestamp="$1"
  local now_epoch current_epoch
  now_epoch=$(get_epoch_seconds)

  # Convert ISO timestamp to epoch (cross-platform)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    current_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo 0)
  else
    current_epoch=$(date -u -d "$timestamp" +%s 2>/dev/null || echo 0)
  fi

  echo $(( (now_epoch - current_epoch) / 60 ))
}

# Calculate next reset time (assumes daily reset at midnight UTC)
calculate_next_reset() {
  local now tomorrow_midnight minutes_until next_reset
  now=$(date -u +%s)

  if [[ "$OSTYPE" == "darwin"* ]]; then
    tomorrow_midnight=$(date -u -v+1d -j -f "%Y-%m-%d" "$(date -u +%Y-%m-%d)" "+%s" 2>/dev/null || echo "$((now + 86400))")
  else
    tomorrow_midnight=$(date -u -d "tomorrow 00:00:00" +%s 2>/dev/null || echo "$((now + 86400))")
  fi

  minutes_until=$(( (tomorrow_midnight - now) / 60 ))

  # Format next reset time
  if [[ "$OSTYPE" == "darwin"* ]]; then
    next_reset=$(date -u -r "$tomorrow_midnight" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
  else
    next_reset=$(date -u -d "@$tomorrow_midnight" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
  fi

  # Output as JSON-friendly format
  echo "{\"next_reset\":\"$next_reset\",\"minutes_until\":$minutes_until}"
}

# Initialize state file with default values
init_state() {
  ensure_state_dir

  local timestamp next_reset_json next_reset minutes_until
  timestamp=$(get_timestamp)
  next_reset_json=$(calculate_next_reset)
  next_reset=$(echo "$next_reset_json" | jq -r '.next_reset')
  minutes_until=$(echo "$next_reset_json" | jq -r '.minutes_until')

  jq -n \
    --arg timestamp "$timestamp" \
    --arg next_reset "$next_reset" \
    --arg minutes_until "$minutes_until" \
    --arg stale_threshold "$STALE_THRESHOLD_MINUTES" \
    '{
      last_updated: $timestamp,
      last_updated_by: "init",
      utilization: {
        current_usage_pct: 0,
        remaining_capacity_pct: 100,
        tokens_used_today: 0,
        estimated_limit: null
      },
      reset_window: {
        type: "static",
        reset_time_utc: "00:00",
        next_reset: $next_reset,
        minutes_until_reset: ($minutes_until | tonumber)
      },
      session: {
        active: false,
        last_work_completed: null,
        last_work_duration_minutes: null,
        work_in_progress: false
      },
      staleness: {
        data_age_minutes: 0,
        is_stale: false,
        stale_threshold_minutes: ($stale_threshold | tonumber)
      }
    }' > "$STATE_FILE"

  chmod 600 "$STATE_FILE"
}

# Read current state
read_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found at $STATE_FILE" >&2
    echo "Run with --init to create it" >&2
    exit 2
  fi

  # Calculate staleness on read
  local state last_updated data_age is_stale
  state=$(cat "$STATE_FILE")
  last_updated=$(echo "$state" | jq -r '.last_updated')
  data_age=$(minutes_since "$last_updated")
  is_stale=$( [ "$data_age" -gt "$STALE_THRESHOLD_MINUTES" ] && echo "true" || echo "false" )

  # Update staleness fields dynamically
  echo "$state" | jq \
    --arg data_age "$data_age" \
    --arg is_stale "$is_stale" \
    '.staleness.data_age_minutes = ($data_age | tonumber) | .staleness.is_stale = ($is_stale == "true")'
}

# Check if state is stale
check_stale() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "true"
    exit 0
  fi

  local last_updated data_age
  last_updated=$(jq -r '.last_updated' "$STATE_FILE")
  data_age=$(minutes_since "$last_updated")

  if [ "$data_age" -gt "$STALE_THRESHOLD_MINUTES" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# Update state after work completion
update_state() {
  local usage_pct="$1"
  local tokens_used="$2"
  local work_duration="${3:-0}"

  ensure_state_dir

  # Initialize if not exists
  if [ ! -f "$STATE_FILE" ]; then
    init_state
  fi

  local timestamp remaining_pct next_reset_json next_reset minutes_until estimated_limit
  timestamp=$(get_timestamp)
  remaining_pct=$((100 - usage_pct))
  next_reset_json=$(calculate_next_reset)
  next_reset=$(echo "$next_reset_json" | jq -r '.next_reset')
  minutes_until=$(echo "$next_reset_json" | jq -r '.minutes_until')

  # Estimate daily limit based on usage percentage
  if [ "$usage_pct" -gt 0 ]; then
    estimated_limit=$((tokens_used * 100 / usage_pct))
  else
    estimated_limit="null"
  fi

  # Update state file
  jq \
    --arg timestamp "$timestamp" \
    --arg usage_pct "$usage_pct" \
    --arg remaining_pct "$remaining_pct" \
    --arg tokens_used "$tokens_used" \
    --arg estimated_limit "$estimated_limit" \
    --arg next_reset "$next_reset" \
    --arg minutes_until "$minutes_until" \
    --arg work_duration "$work_duration" \
    '.last_updated = $timestamp |
     .last_updated_by = "work_completion" |
     .utilization.current_usage_pct = ($usage_pct | tonumber) |
     .utilization.remaining_capacity_pct = ($remaining_pct | tonumber) |
     .utilization.tokens_used_today = ($tokens_used | tonumber) |
     .utilization.estimated_limit = (if $estimated_limit == "null" then null else ($estimated_limit | tonumber) end) |
     .reset_window.next_reset = $next_reset |
     .reset_window.minutes_until_reset = ($minutes_until | tonumber) |
     .session.active = false |
     .session.last_work_completed = $timestamp |
     .session.last_work_duration_minutes = ($work_duration | tonumber) |
     .session.work_in_progress = false |
     .staleness.data_age_minutes = 0 |
     .staleness.is_stale = false' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Mark work as in progress
mark_work_in_progress() {
  ensure_state_dir

  if [ ! -f "$STATE_FILE" ]; then
    init_state
  fi

  local timestamp
  timestamp=$(get_timestamp)

  jq \
    --arg timestamp "$timestamp" \
    '.last_updated = $timestamp |
     .last_updated_by = "work_start" |
     .session.active = true |
     .session.work_in_progress = true' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Refresh state from Claude CLI (costs tokens)
refresh_state() {
  echo "Warning: Refreshing state will make API calls and consume tokens" >&2
  echo "Not yet implemented - requires investigation of Claude CLI usage endpoints" >&2
  exit 1
}

# Parse command line arguments
ACTION=""
USAGE_PCT=""
TOKENS_USED=""
WORK_DURATION=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --read)
      ACTION="read"
      shift
      ;;
    --update)
      ACTION="update"
      shift
      ;;
    --check-stale)
      ACTION="check-stale"
      shift
      ;;
    --refresh)
      ACTION="refresh"
      shift
      ;;
    --init)
      ACTION="init"
      shift
      ;;
    --mark-in-progress)
      ACTION="mark-in-progress"
      shift
      ;;
    --usage)
      USAGE_PCT="$2"
      shift 2
      ;;
    --tokens)
      TOKENS_USED="$2"
      shift 2
      ;;
    --duration)
      WORK_DURATION="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 --read|--update|--check-stale|--refresh|--init [OPTIONS]"
      echo ""
      echo "Actions:"
      echo "  --read               Read current state (free - no token cost)"
      echo "  --update             Update state after work completion"
      echo "  --check-stale        Check if state data is stale (returns true/false)"
      echo "  --refresh            Force refresh from Claude CLI (costs tokens)"
      echo "  --init               Initialize state file with defaults"
      echo "  --mark-in-progress   Mark work as in progress"
      echo ""
      echo "Options for --update:"
      echo "  --usage PCT          Current usage percentage (0-100)"
      echo "  --tokens N           Total tokens used today"
      echo "  --duration MIN       Duration of last work in minutes (optional)"
      echo ""
      echo "Environment:"
      echo "  CLAUDE_STATE_DIR           Override state directory (default: .claude)"
      echo "  CLAUDE_STATE_FILE          Override state file path"
      echo "  CLAUDE_STALE_THRESHOLD     Staleness threshold in minutes (default: 60)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Execute action
case $ACTION in
  read)
    read_state
    ;;
  update)
    if [ -z "$USAGE_PCT" ] || [ -z "$TOKENS_USED" ]; then
      echo "Error: --update requires --usage and --tokens" >&2
      exit 1
    fi
    update_state "$USAGE_PCT" "$TOKENS_USED" "$WORK_DURATION"
    ;;
  check-stale)
    check_stale
    ;;
  refresh)
    refresh_state
    ;;
  init)
    init_state
    echo "Initialized state file at $STATE_FILE"
    ;;
  mark-in-progress)
    mark_work_in_progress
    ;;
  *)
    echo "Error: Must specify --read, --update, --check-stale, --refresh, --init, or --mark-in-progress" >&2
    exit 1
    ;;
esac
