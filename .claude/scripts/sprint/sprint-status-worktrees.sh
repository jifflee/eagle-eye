#!/bin/bash
set -euo pipefail
# sprint-status-worktrees.sh
# Detects worktrees associated with closed issues for cleanup
#
# DESCRIPTION:
#   Scans git worktrees matching the {repo}-issue-{N} naming convention and
#   queries GitHub API to determine if linked issues are closed. Returns JSON
#   with worktrees ready for cleanup.
#
# DEPENDENCIES:
#   - git (with worktree support)
#   - gh (GitHub CLI, authenticated)
#   - jq (JSON processing)
#
# USAGE:
#   ./scripts/sprint-status-worktrees.sh
#
# OUTPUT:
#   JSON object with structure:
#   {
#     "worktrees_for_cleanup": [
#       {
#         "path": "/path/to/repo-issue-13",
#         "issue": 13,
#         "branch": "feat/issue-13",
#         "state": "CLOSED",
#         "closed_at": "2026-01-10T...",
#         "title": "Issue title",
#         "conflicts": "None" | "Uncommitted changes" | "N unpushed commits"
#       }
#     ],
#     "total_issue_worktrees": 4
#   }
#
# NOTES:
#   - Only detects worktrees following {repo}-issue-{N} naming convention
#   - Makes one GitHub API call per matching worktree (consolidated from 3)
#   - Returns empty array if no worktrees match the pattern
#   - Gracefully handles API failures with fallback values
#   - Only checks unpushed commits if upstream tracking exists

set -e

# Check if we're in main repo or a worktree
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ -d "$TOPLEVEL/.git" ]; then
  IS_MAIN_REPO=true
else
  IS_MAIN_REPO=false
fi

# Get repo name for pattern matching
REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
# Handle worktree case: strip -issue-N suffix to get base repo name
REPO_NAME=$(echo "$REPO_NAME" | sed 's/-issue-[0-9]*$//')

# Parse worktree list and extract issue numbers
WORKTREES=()
while IFS= read -r line; do
  WORKTREE_PATH=$(echo "$line" | awk '{print $1}')
  WORKTREE_DIR=$(basename "$WORKTREE_PATH")

  # Extract issue number from directory name pattern: {repo}-issue-{N}
  if [[ "$WORKTREE_DIR" =~ ${REPO_NAME}-issue-([0-9]+)$ ]]; then
    ISSUE_NUM="${BASH_REMATCH[1]}"
    # Extract branch from [branch_name] format using bash regex
    if [[ "$line" =~ \[([^\]]+)\] ]]; then
      BRANCH="${BASH_REMATCH[1]}"
    else
      BRANCH="unknown"
    fi

    # Use jq for safe JSON construction (handles special chars in paths/branches)
    WORKTREES+=("$(jq -n --arg p "$WORKTREE_PATH" --arg b "$BRANCH" --argjson i "$ISSUE_NUM" \
      '{path: $p, issue: $i, branch: $b}')")
  fi
done < <(git worktree list 2>/dev/null)

# If no issue-linked worktrees found
if [ ${#WORKTREES[@]} -eq 0 ]; then
  jq -n --argjson is_main "$IS_MAIN_REPO" '{worktrees_for_cleanup: [], total_issue_worktrees: 0, cleanup_allowed: $is_main}'
  exit 0
fi

# Check issue statuses via GitHub API
CLEANUP_WORKTREES=()
for wt in "${WORKTREES[@]}"; do
  ISSUE_NUM=$(echo "$wt" | jq -r '.issue')

  # Single API call for all issue data (instead of 3 separate calls)
  ISSUE_INFO=$(gh issue view "$ISSUE_NUM" --json state,closedAt,title 2>/dev/null || echo '{}')
  ISSUE_STATE=$(echo "$ISSUE_INFO" | jq -r '.state // "UNKNOWN"')

  if [ "$ISSUE_STATE" = "CLOSED" ]; then
    # Extract from cached API response
    CLOSED_AT=$(echo "$ISSUE_INFO" | jq -r '.closedAt // ""')
    ISSUE_TITLE=$(echo "$ISSUE_INFO" | jq -r '.title // ""')

    # Check for uncommitted changes (conflicts)
    WORKTREE_PATH=$(echo "$wt" | jq -r '.path')
    UNCOMMITTED=$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | head -5)
    if [ -n "$UNCOMMITTED" ]; then
      CONFLICT_STATUS="Uncommitted changes"
    else
      CONFLICT_STATUS="None"
    fi

    # Check for unpushed commits (only if upstream tracking exists)
    if git -C "$WORKTREE_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
      UNPUSHED=$(($(git -C "$WORKTREE_PATH" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l)))
      if [ "$UNPUSHED" -gt 0 ]; then
        if [ "$CONFLICT_STATUS" = "None" ]; then
          CONFLICT_STATUS="$UNPUSHED unpushed commits"
        else
          CONFLICT_STATUS="$CONFLICT_STATUS, $UNPUSHED unpushed commits"
        fi
      fi
    fi

    # Add to cleanup list with additional info
    CLEANUP_ENTRY=$(echo "$wt" | jq \
      --arg state "$ISSUE_STATE" \
      --arg closed_at "$CLOSED_AT" \
      --arg title "$ISSUE_TITLE" \
      --arg conflicts "$CONFLICT_STATUS" \
      '. + {state: $state, closed_at: $closed_at, title: $title, conflicts: $conflicts}')
    CLEANUP_WORKTREES+=("$CLEANUP_ENTRY")
  fi
done

# Build output JSON
if [ ${#CLEANUP_WORKTREES[@]} -eq 0 ]; then
  CLEANUP_JSON="[]"
else
  CLEANUP_JSON=$(printf '%s\n' "${CLEANUP_WORKTREES[@]}" | jq -s '.')
fi

jq -n \
  --argjson cleanup "$CLEANUP_JSON" \
  --argjson total "${#WORKTREES[@]}" \
  --argjson is_main "$IS_MAIN_REPO" \
  '{
    worktrees_for_cleanup: $cleanup,
    total_issue_worktrees: $total,
    cleanup_allowed: $is_main
  }'
