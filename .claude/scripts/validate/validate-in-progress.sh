#!/bin/bash
set -euo pipefail
# validate-in-progress.sh
# Validates in-progress issues to detect orphaned work
#
# DESCRIPTION:
#   Detects in-progress issues without active worktrees, branches, or recent activity.
#   This prevents issues from getting stuck in "in-progress" state indefinitely.
#
# DEPENDENCIES:
#   - git (with worktree and branch support)
#   - gh (GitHub CLI, authenticated)
#   - jq (JSON processing)
#
# USAGE:
#   ./scripts/validate-in-progress.sh [MILESTONE] [--auto-remediate] [--staleness-days N]
#
# OPTIONS:
#   MILESTONE          - Milestone name (default: current milestone)
#   --auto-remediate   - Automatically move orphaned issues back to backlog
#   --staleness-days   - Days without activity before considering stale (default: 7)
#
# OUTPUT:
#   JSON object with structure:
#   {
#     "orphaned_issues": [
#       {
#         "number": 178,
#         "title": "Issue title",
#         "has_worktree": false,
#         "has_branch": false,
#         "has_lock": false,
#         "last_updated": "2026-01-15T...",
#         "days_stale": 14,
#         "recommendation": "Move to backlog"
#       }
#     ],
#     "total_in_progress": 5,
#     "total_orphaned": 2,
#     "remediation": {
#       "enabled": false,
#       "moved_to_backlog": []
#     }
#   }

set -e

# Ensure we're in the repo root
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"error": "Not in a git repository"}'
  exit 1
}

# Parse arguments
MILESTONE=""
AUTO_REMEDIATE=false
STALENESS_DAYS=7

for arg in "$@"; do
  case $arg in
    --auto-remediate)
      AUTO_REMEDIATE=true
      ;;
    --staleness-days)
      shift
      STALENESS_DAYS="$1"
      ;;
    --*)
      ;; # Skip unknown flags
    *)
      if [ -z "$MILESTONE" ]; then
        MILESTONE="$arg"
      fi
      ;;
  esac
  shift || true
done

# Get milestone if not specified
if [ -z "$MILESTONE" ]; then
  MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty')
fi

if [ -z "$MILESTONE" ]; then
  echo '{"error": "No open milestones found"}'
  exit 1
fi

# Get repo name for worktree pattern matching
REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
PARENT_DIR=$(dirname "$(git rev-parse --show-toplevel 2>/dev/null)")

# Get all in-progress issues
IN_PROGRESS_ISSUES=$(gh issue list --milestone "$MILESTONE" --label "in-progress" --state open --json number,title,updatedAt 2>/dev/null || echo '[]')
TOTAL_IN_PROGRESS=$(echo "$IN_PROGRESS_ISSUES" | jq 'length')

if [ "$TOTAL_IN_PROGRESS" -eq 0 ]; then
  jq -n '{orphaned_issues: [], total_in_progress: 0, total_orphaned: 0, remediation: {enabled: false, moved_to_backlog: []}}'
  exit 0
fi

# Get list of active worktrees
ACTIVE_WORKTREES=$(git worktree list 2>/dev/null | awk '{print $1}' | xargs -I{} basename {} | grep -E "${REPO_NAME}-issue-[0-9]+$" | sed "s/${REPO_NAME}-issue-//" || echo "")

# Get list of all branches (local and remote)
ALL_BRANCHES=$(git branch -a 2>/dev/null | sed 's/^[* ]*//' | sed 's/remotes\///')

# Get list of lock files
LOCK_DIR=".sprint-locks"
LOCK_FILES=()
if [ -d "$LOCK_DIR" ]; then
  while IFS= read -r lock_file; do
    if [[ "$(basename "$lock_file")" =~ issue-([0-9]+)\.lock$ ]]; then
      LOCK_FILES+=("${BASH_REMATCH[1]}")
    fi
  done < <(find "$LOCK_DIR" -name "issue-*.lock" 2>/dev/null || true)
fi

# Calculate staleness threshold
STALENESS_THRESHOLD_DATE=$(date -u -v-${STALENESS_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${STALENESS_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)

# Check each in-progress issue
ORPHANED_ISSUES=()
REMEDIATED_ISSUES=()

while IFS= read -r issue; do
  ISSUE_NUM=$(echo "$issue" | jq -r '.number')
  ISSUE_TITLE=$(echo "$issue" | jq -r '.title')
  LAST_UPDATED=$(echo "$issue" | jq -r '.updatedAt')

  # Check if worktree exists
  HAS_WORKTREE=false
  if echo "$ACTIVE_WORKTREES" | grep -q "^${ISSUE_NUM}$"; then
    HAS_WORKTREE=true
  fi

  # Check if branch exists (feat/issue-N or any branch containing issue-N)
  HAS_BRANCH=false
  if echo "$ALL_BRANCHES" | grep -qE "(feat/issue-${ISSUE_NUM}|issue-${ISSUE_NUM})"; then
    HAS_BRANCH=true
  fi

  # Check if lock file exists
  HAS_LOCK=false
  for lock_num in "${LOCK_FILES[@]}"; do
    if [ "$lock_num" = "$ISSUE_NUM" ]; then
      HAS_LOCK=true
      break
    fi
  done

  # Calculate days stale
  DAYS_STALE=0
  if command -v python3 >/dev/null 2>&1; then
    DAYS_STALE=$(python3 -c "from datetime import datetime; print((datetime.now() - datetime.fromisoformat('${LAST_UPDATED}'.replace('Z', '+00:00'))).days)" 2>/dev/null || echo 0)
  fi

  # Determine if orphaned (no worktree AND no branch AND stale)
  IS_ORPHANED=false
  RECOMMENDATION=""

  if [ "$HAS_WORKTREE" = false ] && [ "$HAS_BRANCH" = false ]; then
    IS_ORPHANED=true
    if [ "$DAYS_STALE" -ge "$STALENESS_DAYS" ]; then
      RECOMMENDATION="Move to backlog (stale)"
    else
      RECOMMENDATION="Move to backlog or create worktree"
    fi
  elif [ "$HAS_WORKTREE" = false ] && [ "$HAS_BRANCH" = true ]; then
    # Has branch but no worktree - might be legitimate (pushed to remote)
    if [ "$DAYS_STALE" -ge "$STALENESS_DAYS" ]; then
      IS_ORPHANED=true
      RECOMMENDATION="Review progress or move to backlog"
    fi
  elif [ "$HAS_WORKTREE" = true ] && [ "$HAS_BRANCH" = false ]; then
    # Has worktree but no branch - unusual state
    RECOMMENDATION="Verify worktree state"
  fi

  # Build orphaned issue entry
  if [ "$IS_ORPHANED" = true ]; then
    ORPHAN_ENTRY=$(jq -n \
      --argjson num "$ISSUE_NUM" \
      --arg title "$ISSUE_TITLE" \
      --argjson has_wt "$HAS_WORKTREE" \
      --argjson has_br "$HAS_BRANCH" \
      --argjson has_lk "$HAS_LOCK" \
      --arg updated "$LAST_UPDATED" \
      --argjson days "$DAYS_STALE" \
      --arg rec "$RECOMMENDATION" \
      '{
        number: $num,
        title: $title,
        has_worktree: $has_wt,
        has_branch: $has_br,
        has_lock: $has_lk,
        last_updated: $updated,
        days_stale: $days,
        recommendation: $rec
      }')
    ORPHANED_ISSUES+=("$ORPHAN_ENTRY")

    # Auto-remediate if enabled
    if [ "$AUTO_REMEDIATE" = true ]; then
      # Remove in-progress label and add backlog label
      gh issue edit "$ISSUE_NUM" --remove-label "in-progress" --add-label "backlog" 2>/dev/null || true
      # Add comment explaining the change
      gh issue comment "$ISSUE_NUM" --body "Auto-moved to backlog: No active worktree or branch found, and issue has been inactive for ${DAYS_STALE} days.

To resume work, use: \`/sprint-work --issue $ISSUE_NUM\`" 2>/dev/null || true
      REMEDIATED_ISSUES+=("$ISSUE_NUM")
    fi
  fi
done < <(echo "$IN_PROGRESS_ISSUES" | jq -c '.[]')

# Build output JSON
if [ ${#ORPHANED_ISSUES[@]} -eq 0 ]; then
  ORPHANED_JSON="[]"
else
  ORPHANED_JSON=$(printf '%s\n' "${ORPHANED_ISSUES[@]}" | jq -s '.')
fi

if [ ${#REMEDIATED_ISSUES[@]} -eq 0 ]; then
  REMEDIATED_JSON="[]"
else
  REMEDIATED_JSON=$(printf '%s\n' "${REMEDIATED_ISSUES[@]}" | jq -n '[inputs]' --args "${REMEDIATED_ISSUES[@]}")
fi

jq -n \
  --argjson orphaned "$ORPHANED_JSON" \
  --argjson total "$TOTAL_IN_PROGRESS" \
  --argjson total_orphaned "${#ORPHANED_ISSUES[@]}" \
  --argjson auto_rem "$AUTO_REMEDIATE" \
  --argjson remediated "$REMEDIATED_JSON" \
  '{
    orphaned_issues: $orphaned,
    total_in_progress: $total,
    total_orphaned: $total_orphaned,
    remediation: {
      enabled: $auto_rem,
      moved_to_backlog: $remediated
    }
  }'
