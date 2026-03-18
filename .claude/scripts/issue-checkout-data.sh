#!/bin/bash
set -euo pipefail
# issues-checkout-data.sh
# Gathers issue checkout state and validates checkout eligibility
#
# Usage:
#   ./scripts/issue-checkout-data.sh <issue_number>     # Check issue status
#   ./scripts/issue-checkout-data.sh --current          # Show current checkouts
#   ./scripts/issue-checkout-data.sh --validate <num>   # Validate for checkout
#
# Outputs structured JSON with issue state, lock status, and eligibility

set -e

ISSUE_NUMBER=""
CURRENT=false
VALIDATE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --current)
      CURRENT=true
      shift
      ;;
    --validate)
      VALIDATE=true
      ISSUE_NUMBER="$2"
      shift 2
      ;;
    *)
      ISSUE_NUMBER="$1"
      shift
      ;;
  esac
done

# Generate instance ID
INSTANCE_ID="${HOSTNAME:-$(hostname)}-$$-$(date +%s)"
SESSION_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Get stable user/machine identifiers
CURRENT_USER="${USER:-$(whoami)}"
CURRENT_MACHINE="${HOSTNAME:-$(hostname)}"
# Remove any trailing domain from hostname
CURRENT_MACHINE="${CURRENT_MACHINE%%.*}"

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

# Function to check issue status
check_issue_status() {
  local number="$1"

  # Fetch issue data with single API call
  local issue_data=$(gh issue view "$number" --json number,title,state,labels,milestone 2>/dev/null)

  if [ -z "$issue_data" ]; then
    echo '{"error": "Issue not found", "number": '"$number"'}'
    return 1
  fi

  local title=$(echo "$issue_data" | jq -r '.title')
  local state=$(echo "$issue_data" | jq -r '.state')
  local labels=$(echo "$issue_data" | jq -r '[.labels[].name]')
  local milestone=$(echo "$issue_data" | jq -r '.milestone.title // "none"')

  # Check if already checked out
  local is_checked_out=false
  if echo "$labels" | jq -e 'contains(["wip:checked-out"])' > /dev/null 2>&1; then
    is_checked_out=true
  fi

  # Check local locks
  local local_lock=$(get_local_locks | jq --arg n "$number" '.locks[] | select(.issue == ($n | tonumber)) // null')
  local has_local_lock=false
  local lock_instance=""
  local lock_started=""
  local lock_heartbeat=""
  local lock_user=""
  local lock_machine=""
  local is_stale=false
  local is_same_user=false

  if [ -n "$local_lock" ] && [ "$local_lock" != "null" ]; then
    has_local_lock=true
    lock_instance=$(echo "$local_lock" | jq -r '.instance_id')
    lock_started=$(echo "$local_lock" | jq -r '.started_at')
    lock_heartbeat=$(echo "$local_lock" | jq -r '.last_heartbeat // .started_at')
    lock_user=$(echo "$local_lock" | jq -r '.user // "unknown"')
    lock_machine=$(echo "$local_lock" | jq -r '.machine // "unknown"')

    # Check if same user and machine
    if [ "$lock_user" = "$CURRENT_USER" ] && [ "$lock_machine" = "$CURRENT_MACHINE" ]; then
      is_same_user=true
    fi

    # Calculate staleness (30 min threshold)
    local now=$(date +%s)
    if command -v gdate >/dev/null 2>&1; then
      lock_heartbeat_ts=$(gdate -d "$lock_heartbeat" +%s 2>/dev/null || echo "$now")
    else
      lock_heartbeat_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$lock_heartbeat" +%s 2>/dev/null || echo "$now")
    fi
    local age_seconds=$((now - lock_heartbeat_ts))
    local stale_threshold=$((30 * 60))  # 30 minutes

    if [ $age_seconds -gt $stale_threshold ]; then
      is_stale=true
    fi
  fi

  # Determine eligibility
  local can_checkout=true
  local block_reason="none"
  local can_reclaim=false
  local reclaim_reason=""

  if [ "$state" = "CLOSED" ]; then
    can_checkout=false
    block_reason="issue_closed"
  elif [ "$is_checked_out" = true ]; then
    # Check if can reclaim
    if [ "$is_same_user" = true ] && [ "$is_stale" = true ]; then
      can_checkout=true
      can_reclaim=true
      reclaim_reason="same_user_stale_lock"
    else
      can_checkout=false
      block_reason="already_checked_out"
    fi
  fi

  cat <<EOF
{
  "number": $number,
  "title": $(echo "$title" | jq -Rs .),
  "state": "$state",
  "milestone": "$milestone",
  "labels": $labels,
  "checkout_status": {
    "is_checked_out": $is_checked_out,
    "has_local_lock": $has_local_lock,
    "lock_instance": $([ -n "$lock_instance" ] && echo "\"$lock_instance\"" || echo "null"),
    "lock_started": $([ -n "$lock_started" ] && echo "\"$lock_started\"" || echo "null"),
    "lock_heartbeat": $([ -n "$lock_heartbeat" ] && echo "\"$lock_heartbeat\"" || echo "null"),
    "lock_user": $([ -n "$lock_user" ] && echo "\"$lock_user\"" || echo "null"),
    "lock_machine": $([ -n "$lock_machine" ] && echo "\"$lock_machine\"" || echo "null"),
    "is_stale": $is_stale,
    "is_same_user": $is_same_user
  },
  "eligibility": {
    "can_checkout": $can_checkout,
    "block_reason": "$block_reason",
    "can_reclaim": $can_reclaim,
    "reclaim_reason": "$reclaim_reason"
  },
  "new_checkout": {
    "instance_id": "$INSTANCE_ID",
    "session_start": "$SESSION_START",
    "user": "$CURRENT_USER",
    "machine": "$CURRENT_MACHINE"
  }
}
EOF
}

# Function to list current checkouts
list_current_checkouts() {
  # Get issues with wip:checked-out label
  local checked_out=$(gh issue list --label "wip:checked-out" --state open --json number,title,labels,updatedAt 2>/dev/null || echo "[]")

  # Get local locks
  local local_locks=$(get_local_locks)

  # Merge the data
  cat <<EOF
{
  "github_checkouts": $checked_out,
  "local_locks": $local_locks,
  "current_instance": "$INSTANCE_ID",
  "checked_at": "$SESSION_START"
}
EOF
}

# Main execution
if [ "$CURRENT" = true ]; then
  list_current_checkouts
elif [ -n "$ISSUE_NUMBER" ]; then
  check_issue_status "$ISSUE_NUMBER"
else
  echo '{"error": "Usage: issues-checkout-data.sh <number> | --current | --validate <number>"}'
  exit 1
fi
