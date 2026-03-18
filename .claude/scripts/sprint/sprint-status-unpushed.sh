#!/bin/bash
set -euo pipefail
# sprint-status-unpushed.sh
# Detects unpushed work in worktrees for both open and closed issues
#
# DESCRIPTION:
#   Scans git worktrees and reports unpushed commits/uncommitted changes
#   Provides actionable recommendations with risk categorization
#   Supports interactive remediation (archive/discard workflows)
#
# RISK LEVELS:
#   HIGH - Issue CLOSED + NO PR merged + commits exist (work may be lost)
#   HIGH - >10 unpushed commits (significant work at risk)
#   MED  - Uncommitted changes present (active work needs attention)
#   LOW  - Issue CLOSED + PR merged + commits exist (duplicates, safe to discard)
#
# USAGE:
#   ./scripts/sprint-status-unpushed.sh [--json-only]
#
# OUTPUT:
#   JSON with unpushed work details, risk levels, and remediation actions

set -e

REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
REPO_NAME=$(echo "$REPO_NAME" | sed 's/-issue-[0-9]*$//')

# Ensure log directory exists
LOG_DIR="$HOME/.claude-tastic/logs"
mkdir -p "$LOG_DIR"

UNPUSHED_WORK=()

while IFS= read -r line; do
  WORKTREE_PATH=$(echo "$line" | awk '{print $1}')
  WORKTREE_DIR=$(basename "$WORKTREE_PATH")

  if [[ "$WORKTREE_DIR" =~ ${REPO_NAME}-issue-([0-9]+)$ ]]; then
    ISSUE_NUM="${BASH_REMATCH[1]}"

    # Get branch name
    if [[ "$line" =~ \[([^\]]+)\] ]]; then
      BRANCH="${BASH_REMATCH[1]}"
    else
      BRANCH="unknown"
    fi

    # Check for uncommitted changes
    UNCOMMITTED_COUNT=$(($(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | wc -l)))

    # Check for unpushed commits
    UNPUSHED_COUNT=0
    if git -C "$WORKTREE_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
      UNPUSHED_COUNT=$(($(git -C "$WORKTREE_PATH" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l)))
    fi

    # Skip if no unpushed work
    if [ "$UNCOMMITTED_COUNT" -eq 0 ] && [ "$UNPUSHED_COUNT" -eq 0 ]; then
      continue
    fi

    # Get issue state
    ISSUE_INFO=$(gh issue view "$ISSUE_NUM" --json state,title 2>/dev/null || echo '{"state": "UNKNOWN", "title": ""}')
    ISSUE_STATE=$(echo "$ISSUE_INFO" | jq -r '.state // "UNKNOWN"')
    ISSUE_TITLE=$(echo "$ISSUE_INFO" | jq -r '.title // ""')

    # Check if PR was merged for this branch
    PR_MERGED="false"
    PR_NUMBER=""
    if [ "$BRANCH" != "unknown" ]; then
      PR_INFO=$(gh pr list --head "$BRANCH" --state merged --json number --limit 1 2>/dev/null || echo '[]')
      if [ "$PR_INFO" != "[]" ] && [ -n "$PR_INFO" ]; then
        PR_MERGED="true"
        PR_NUMBER=$(echo "$PR_INFO" | jq -r '.[0].number // ""')
      fi
    fi

    # Get last commit message and date (truncate message to 80 chars for safety)
    LAST_COMMIT_MSG=$(git -C "$WORKTREE_PATH" log -1 --format="%s" 2>/dev/null | head -c 80 | tr -d '\n\r\t' || echo "")
    LAST_COMMIT_DATE=$(git -C "$WORKTREE_PATH" log -1 --format="%ci" 2>/dev/null | head -1 || echo "")

    # Determine risk level and recommendation based on context
    # Risk Matrix:
    #   HIGH - Work may be permanently lost
    #   MED  - Active work needs attention
    #   LOW  - Safe to discard (PR merged, work preserved)
    RISK_LEVEL="LOW"
    RECOMMENDED_ACTION="review"

    if [ "$ISSUE_STATE" = "CLOSED" ]; then
      if [ "$PR_MERGED" = "true" ]; then
        # Issue closed AND PR merged - commits are likely stale duplicates
        RISK_LEVEL="LOW"
        RECOMMENDED_ACTION="discard"
        RECOMMENDATION="Safe to discard (PR #$PR_NUMBER merged)"
      elif [ "$UNPUSHED_COUNT" -gt 10 ]; then
        # Significant unpushed work with no PR - HIGH RISK
        RISK_LEVEL="HIGH"
        RECOMMENDED_ACTION="archive"
        RECOMMENDATION="Archive to archive/$BRANCH (significant unpushed work)"
      elif [ "$UNPUSHED_COUNT" -gt 0 ]; then
        # Some unpushed work with no PR - HIGH RISK
        RISK_LEVEL="HIGH"
        RECOMMENDED_ACTION="archive"
        RECOMMENDATION="Archive: Work may be lost (no PR merged)"
      else
        # Only uncommitted changes, issue closed
        RISK_LEVEL="MED"
        RECOMMENDED_ACTION="review"
        RECOMMENDATION="Review uncommitted changes before cleanup"
      fi
    else
      # Issue is OPEN
      if [ "$UNCOMMITTED_COUNT" -gt 0 ]; then
        RISK_LEVEL="MED"
        RECOMMENDED_ACTION="commit"
        RECOMMENDATION="Commit and push active changes"
      elif [ "$UNPUSHED_COUNT" -gt 0 ]; then
        RISK_LEVEL="MED"
        RECOMMENDED_ACTION="push"
        RECOMMENDATION="Push commits to preserve work"
      fi
    fi

    ENTRY=$(jq -n \
      --argjson issue "$ISSUE_NUM" \
      --arg title "$ISSUE_TITLE" \
      --arg state "$ISSUE_STATE" \
      --arg path "$WORKTREE_PATH" \
      --arg branch "$BRANCH" \
      --argjson uncommitted "$UNCOMMITTED_COUNT" \
      --argjson unpushed "$UNPUSHED_COUNT" \
      --arg last_commit "$LAST_COMMIT_MSG" \
      --arg last_date "$LAST_COMMIT_DATE" \
      --arg recommendation "$RECOMMENDATION" \
      --arg risk_level "$RISK_LEVEL" \
      --arg recommended_action "$RECOMMENDED_ACTION" \
      --argjson pr_merged "$PR_MERGED" \
      --arg pr_number "$PR_NUMBER" \
      '{
        issue: $issue,
        title: $title,
        state: $state,
        path: $path,
        branch: $branch,
        uncommitted_files: $uncommitted,
        unpushed_commits: $unpushed,
        last_commit: $last_commit,
        last_commit_date: $last_date,
        recommendation: $recommendation,
        risk_level: $risk_level,
        recommended_action: $recommended_action,
        pr_merged: $pr_merged,
        pr_number: $pr_number
      }')
    UNPUSHED_WORK+=("$ENTRY")
  fi
done < <(git worktree list 2>/dev/null)

# Build output JSON with risk counts
if [ ${#UNPUSHED_WORK[@]} -eq 0 ]; then
  echo '{"unpushed_work": [], "total_with_unpushed": 0, "risk_counts": {"HIGH": 0, "MED": 0, "LOW": 0}}'
else
  WORK_JSON=$(printf '%s\n' "${UNPUSHED_WORK[@]}" | jq -s '.')
  jq -n \
    --argjson work "$WORK_JSON" \
    '{
      unpushed_work: $work,
      total_with_unpushed: ($work | length),
      risk_counts: {
        HIGH: ([$work[] | select(.risk_level == "HIGH")] | length),
        MED: ([$work[] | select(.risk_level == "MED")] | length),
        LOW: ([$work[] | select(.risk_level == "LOW")] | length)
      }
    }'
fi
