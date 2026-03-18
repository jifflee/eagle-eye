#!/bin/bash
set -euo pipefail
# issues-release-data.sh
# Gathers issue checkout data for releasing locks
#
# Usage:
#   ./scripts/issue-release-data.sh <issue_number>  # Check specific issue
#   ./scripts/issue-release-data.sh --all           # Get all locks for this instance
#
# Outputs structured JSON with lock status and release eligibility

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

# Get instance ID
INSTANCE_ID="${HOSTNAME:-$(hostname)}-$$"
CURRENT_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Get local locks file path
LOCKS_FILE=".claude-locks.json"

# Function to get local locks
get_local_locks() {
  if [ -f "$LOCKS_FILE" ]; then
    cat "$LOCKS_FILE"
  else
    echo '{"locks": []}'
  fi
}

# Function to calculate duration
calculate_duration() {
  local start="$1"
  local now=$(date +%s)

  # Parse start time
  if command -v gdate >/dev/null 2>&1; then
    start_ts=$(gdate -d "$start" +%s 2>/dev/null || echo "$now")
  else
    start_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start" +%s 2>/dev/null || echo "$now")
  fi

  local duration=$((now - start_ts))
  local minutes=$((duration / 60))

  echo "$minutes"
}

# Function to get issue details
get_issue_details() {
  local number="$1"
  gh issue view "$number" --json number,title,state,labels --jq '{number, title, state, labels: [.labels[].name]}'
}

# Function to check single issue
check_issue() {
  local number="$1"
  local local_locks=$(get_local_locks)

  # Get issue details
  local issue=$(get_issue_details "$number" 2>/dev/null || echo '{"error": "not_found"}')

  if echo "$issue" | jq -e '.error' > /dev/null 2>&1; then
    echo '{"error": "Issue not found", "number": '"$number"'}'
    return 1
  fi

  # Check if has checkout label
  local has_label=false
  if echo "$issue" | jq -e '.labels | contains(["wip:checked-out"])' > /dev/null 2>&1; then
    has_label=true
  fi

  # Check local lock
  local lock=$(echo "$local_locks" | jq --arg n "$number" '.locks[] | select(.issue == ($n | tonumber)) // null')
  local has_lock=false
  local lock_instance=""
  local lock_started=""
  local lock_heartbeat=""
  local lock_user=""
  local lock_machine=""
  local duration_min=0
  local heartbeat_age_min=0

  if [ -n "$lock" ] && [ "$lock" != "null" ]; then
    has_lock=true
    lock_instance=$(echo "$lock" | jq -r '.instance_id')
    lock_started=$(echo "$lock" | jq -r '.started_at')
    lock_heartbeat=$(echo "$lock" | jq -r '.last_heartbeat // .started_at')
    lock_user=$(echo "$lock" | jq -r '.user // "unknown"')
    lock_machine=$(echo "$lock" | jq -r '.machine // "unknown"')
    duration_min=$(calculate_duration "$lock_started")
    heartbeat_age_min=$(calculate_duration "$lock_heartbeat")
  fi

  # Determine if can release
  local can_release=false
  local release_type="none"

  if [ "$has_lock" = true ]; then
    can_release=true
    release_type="local_and_github"
  elif [ "$has_label" = true ]; then
    can_release=true
    release_type="github_only"
  fi

  # Get current branch
  local current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")

  cat <<EOF
{
  "issue": $issue,
  "lock_status": {
    "has_github_label": $has_label,
    "has_local_lock": $has_lock,
    "lock_instance": $([ -n "$lock_instance" ] && echo "\"$lock_instance\"" || echo "null"),
    "lock_started": $([ -n "$lock_started" ] && echo "\"$lock_started\"" || echo "null"),
    "lock_heartbeat": $([ -n "$lock_heartbeat" ] && echo "\"$lock_heartbeat\"" || echo "null"),
    "lock_user": $([ -n "$lock_user" ] && echo "\"$lock_user\"" || echo "null"),
    "lock_machine": $([ -n "$lock_machine" ] && echo "\"$lock_machine\"" || echo "null"),
    "duration_minutes": $duration_min,
    "heartbeat_age_minutes": $heartbeat_age_min
  },
  "release": {
    "can_release": $can_release,
    "release_type": "$release_type"
  },
  "context": {
    "current_branch": "$current_branch",
    "current_instance": "$INSTANCE_ID"
  },
  "checked_at": "$CURRENT_TIME"
}
EOF
}

# Function to get all locks
get_all_locks() {
  local local_locks=$(get_local_locks)

  # Get all GitHub issues with checkout label
  local github_checkouts=$(gh issue list --label "wip:checked-out" --state open --json number,title,updatedAt 2>/dev/null || echo "[]")

  # Filter local locks by current instance prefix
  local instance_locks=$(echo "$local_locks" | jq --arg prefix "$INSTANCE_ID" '.locks | map(select(.instance_id | startswith($prefix)))')

  cat <<EOF
{
  "github_checkouts": $github_checkouts,
  "local_locks": $local_locks,
  "instance_locks": $instance_locks,
  "current_instance": "$INSTANCE_ID",
  "checked_at": "$CURRENT_TIME"
}
EOF
}

# Main execution
if [ "$ALL" = true ]; then
  get_all_locks
elif [ -n "$ISSUE_NUMBER" ]; then
  check_issue "$ISSUE_NUMBER"
else
  echo '{"error": "Usage: issues-release-data.sh <number> | --all"}'
  exit 1
fi
