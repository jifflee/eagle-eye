#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: cleanup-tracking.sh
# Purpose: Track auto-cleanup intent for PRs
# Usage: Source this library for cleanup tracking functions
#
# This library manages tracking of PRs that should be
# auto-cleaned after merge. Uses local JSON file storage.
#
# Issue: #104 - Add --cleanup-after-merge flag to PR creation
# ============================================================

# Source framework config to get FRAMEWORK_DIR
_CLEANUP_TRACKING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_CLEANUP_TRACKING_LIB_DIR}/framework-config.sh"

# Storage location
CLEANUP_TRACKING_DIR="${FRAMEWORK_DIR}"
CLEANUP_TRACKING_FILE="${CLEANUP_TRACKING_DIR}/pending-cleanup.json"

# Ensure tracking directory and file exist
ensure_tracking_file() {
  mkdir -p "$CLEANUP_TRACKING_DIR"

  if [ ! -f "$CLEANUP_TRACKING_FILE" ]; then
    echo '{"version": "1.0", "pending_cleanups": []}' > "$CLEANUP_TRACKING_FILE"
  fi
}

# Add a PR to the cleanup tracking list
# Args: issue_number pr_number branch_name [worktree_path] [mode]
add_cleanup_intent() {
  local issue="$1"
  local pr="${2:-}"
  local branch="$3"
  local worktree_path="${4:-}"
  local mode="${5:-worktree}"  # worktree or container

  ensure_tracking_file

  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Create new entry
  local new_entry
  new_entry=$(jq -n \
    --arg issue "$issue" \
    --arg pr "$pr" \
    --arg branch "$branch" \
    --arg worktree "$worktree_path" \
    --arg mode "$mode" \
    --arg ts "$timestamp" \
    '{
      issue: ($issue | tonumber),
      pr: (if $pr == "" then null else ($pr | tonumber) end),
      branch: $branch,
      worktree_path: (if $worktree == "" then null else $worktree end),
      mode: $mode,
      added_at: $ts,
      status: "pending"
    }')

  # Add to tracking file (avoid duplicates by issue)
  local updated
  updated=$(jq \
    --argjson entry "$new_entry" \
    '.pending_cleanups |= (
      map(select(.issue != $entry.issue)) + [$entry]
    )' \
    "$CLEANUP_TRACKING_FILE")

  echo "$updated" > "$CLEANUP_TRACKING_FILE"

  return 0
}

# Update PR number for a tracked issue
# Args: issue_number pr_number
update_pr_number() {
  local issue="$1"
  local pr="$2"

  ensure_tracking_file

  local updated
  updated=$(jq \
    --arg issue "$issue" \
    --arg pr "$pr" \
    '.pending_cleanups |= map(
      if .issue == ($issue | tonumber)
      then .pr = ($pr | tonumber)
      else .
      end
    )' \
    "$CLEANUP_TRACKING_FILE")

  echo "$updated" > "$CLEANUP_TRACKING_FILE"

  return 0
}

# Check if an issue has cleanup intent
# Args: issue_number
# Returns: 0 if cleanup intent exists, 1 otherwise
has_cleanup_intent() {
  local issue="$1"

  ensure_tracking_file

  local count
  count=$(jq \
    --arg issue "$issue" \
    '[.pending_cleanups[] | select(.issue == ($issue | tonumber) and .status == "pending")] | length' \
    "$CLEANUP_TRACKING_FILE")

  [ "$count" -gt 0 ]
}

# Get cleanup entry for an issue
# Args: issue_number
# Returns: JSON object or null
get_cleanup_entry() {
  local issue="$1"

  ensure_tracking_file

  local result
  result=$(jq \
    --arg issue "$issue" \
    '[.pending_cleanups[] | select(.issue == ($issue | tonumber) and .status == "pending")] | if length > 0 then .[0] else null end' \
    "$CLEANUP_TRACKING_FILE")

  echo "$result"
}

# Mark cleanup as completed
# Args: issue_number
complete_cleanup() {
  local issue="$1"

  ensure_tracking_file

  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local updated
  updated=$(jq \
    --arg issue "$issue" \
    --arg ts "$timestamp" \
    '.pending_cleanups |= map(
      if .issue == ($issue | tonumber) and .status == "pending"
      then .status = "completed" | .completed_at = $ts
      else .
      end
    )' \
    "$CLEANUP_TRACKING_FILE")

  echo "$updated" > "$CLEANUP_TRACKING_FILE"

  return 0
}

# Remove a cleanup entry
# Args: issue_number
remove_cleanup_entry() {
  local issue="$1"

  ensure_tracking_file

  local updated
  updated=$(jq \
    --arg issue "$issue" \
    '.pending_cleanups |= map(select(.issue != ($issue | tonumber)))' \
    "$CLEANUP_TRACKING_FILE")

  echo "$updated" > "$CLEANUP_TRACKING_FILE"

  return 0
}

# List all pending cleanups
# Returns: JSON array
list_pending_cleanups() {
  ensure_tracking_file

  jq '.pending_cleanups[] | select(.status == "pending")' "$CLEANUP_TRACKING_FILE"
}

# Prune old completed entries (older than 30 days)
prune_old_entries() {
  ensure_tracking_file

  local cutoff_date
  cutoff_date=$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                date -u -v-30d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)

  local updated
  updated=$(jq \
    --arg cutoff "$cutoff_date" \
    '.pending_cleanups |= map(
      select(
        .status == "pending" or
        (.completed_at // .added_at) > $cutoff
      )
    )' \
    "$CLEANUP_TRACKING_FILE")

  echo "$updated" > "$CLEANUP_TRACKING_FILE"

  return 0
}

# Export functions for use in other scripts
export -f ensure_tracking_file
export -f add_cleanup_intent
export -f update_pr_number
export -f has_cleanup_intent
export -f get_cleanup_entry
export -f complete_cleanup
export -f remove_cleanup_entry
export -f list_pending_cleanups
export -f prune_old_entries
