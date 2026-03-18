#!/bin/bash
set -euo pipefail
# issues-locks-data.sh
# Shows all currently checked-out issues across Claude instances
#
# Usage:
#   ./scripts/issue-locks-data.sh              # Show all locks
#   ./scripts/issue-locks-data.sh --local      # Local locks only
#   ./scripts/issue-locks-data.sh --github     # GitHub locks only
#
# Outputs structured JSON with all lock information

set -e

LOCAL_ONLY=false
GITHUB_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --local)
      LOCAL_ONLY=true
      shift
      ;;
    --github)
      GITHUB_ONLY=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

LOCKS_FILE=".claude-locks.json"
CURRENT_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Get current user and machine for comparison
CURRENT_USER="${USER:-$(whoami)}"
CURRENT_MACHINE="${HOSTNAME:-$(hostname)}"
CURRENT_MACHINE="${CURRENT_MACHINE%%.*}"

# Function to calculate staleness
is_lock_stale() {
  local heartbeat="$1"
  local started="$2"
  local now=$(date +%s)

  # Use heartbeat if available, otherwise started time
  local check_time="${heartbeat:-$started}"

  if command -v gdate >/dev/null 2>&1; then
    check_ts=$(gdate -d "$check_time" +%s 2>/dev/null || echo "$now")
  else
    check_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$check_time" +%s 2>/dev/null || echo "$now")
  fi

  local age_seconds=$((now - check_ts))
  local stale_threshold=$((30 * 60))  # 30 minutes

  if [ $age_seconds -gt $stale_threshold ]; then
    echo "true"
  else
    echo "false"
  fi
}

# Function to calculate age in minutes
calculate_age_minutes() {
  local timestamp="$1"
  local now=$(date +%s)

  if command -v gdate >/dev/null 2>&1; then
    ts=$(gdate -d "$timestamp" +%s 2>/dev/null || echo "$now")
  else
    ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo "$now")
  fi

  echo $(( (now - ts) / 60 ))
}

# Function to get local locks with enrichment
get_local_locks() {
  if [ -f "$LOCKS_FILE" ]; then
    local locks_raw=$(cat "$LOCKS_FILE" | jq -c '.locks // []')
    local enriched_locks='[]'

    # Process each lock
    while IFS= read -r lock; do
      [ -z "$lock" ] && continue

      local heartbeat=$(echo "$lock" | jq -r '.last_heartbeat // .started_at')
      local user=$(echo "$lock" | jq -r '.user // "unknown"')
      local machine=$(echo "$lock" | jq -r '.machine // "unknown"')

      local age_min=$(calculate_age_minutes "$heartbeat")
      local is_stale="false"
      [ $age_min -gt 30 ] && is_stale="true"

      local is_same_user="false"
      [ "$user" = "$CURRENT_USER" ] && [ "$machine" = "$CURRENT_MACHINE" ] && is_same_user="true"

      # Add enriched fields
      enriched_locks=$(echo "$enriched_locks" | jq \
        --argjson lock "$lock" \
        --argjson age_min "$age_min" \
        --arg is_stale "$is_stale" \
        --arg is_same_user "$is_same_user" \
        '. += [$lock + {heartbeat_age_minutes: $age_min, is_stale: ($is_stale == "true"), is_same_user: ($is_same_user == "true")}]')
    done < <(echo "$locks_raw" | jq -c '.[]')

    echo "$enriched_locks"
  else
    echo '[]'
  fi
}

# Function to get GitHub locks
get_github_locks() {
  gh issue list --label "wip:checked-out" --state open \
    --json number,title,updatedAt,labels \
    --jq '[.[] | {number, title, updated_at: .updatedAt}]' 2>/dev/null || echo '[]'
}

# Get locks based on mode
local_locks='[]'
github_locks='[]'

if [ "$GITHUB_ONLY" != true ]; then
  local_locks=$(get_local_locks)
fi

if [ "$LOCAL_ONLY" != true ]; then
  github_locks=$(get_github_locks)
fi

# Calculate stats
local_count=$(echo "$local_locks" | jq 'length')
github_count=$(echo "$github_locks" | jq 'length')

# Merge and deduplicate
all_issues=$(echo "$github_locks" | jq '[.[].number]')

cat <<EOF
{
  "local_locks": $local_locks,
  "github_locks": $github_locks,
  "summary": {
    "local_count": $local_count,
    "github_count": $github_count,
    "unique_issues": $all_issues
  },
  "locks_file": "$LOCKS_FILE",
  "checked_at": "$CURRENT_TIME"
}
EOF
