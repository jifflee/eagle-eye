#!/bin/bash
set -euo pipefail
# pr-status-data.sh
# Gathers PR and review state data for pr-status skill
# size-ok: single-purpose data script batching GitHub API calls
#
# Usage:
#   ./scripts/pr-status-data.sh                    # Current branch's PR
#   ./scripts/pr-status-data.sh --issue 123        # PR for specific issue
#   ./scripts/pr-status-data.sh --pr 456           # Specific PR number
#
# Outputs structured JSON with PR info, checks, and review state

set -e

# Defaults
ISSUE_NUMBER=""
PR_NUMBER=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --issue)
      ISSUE_NUMBER="$2"
      shift 2
      ;;
    --pr)
      PR_NUMBER="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# If --issue provided, find worktree and switch context
WORKTREE_PATH=""
if [ -n "$ISSUE_NUMBER" ]; then
  WORKTREE_PATH=$(git worktree list --porcelain 2>/dev/null | grep -B2 "issue-${ISSUE_NUMBER}" | grep "worktree" | cut -d' ' -f2 || true)
  if [ -z "$WORKTREE_PATH" ]; then
    cat <<EOF
{
  "error": "worktree_not_found",
  "message": "No worktree found for issue #${ISSUE_NUMBER}",
  "suggestion": "Create worktree with: /sprint-work --issue ${ISSUE_NUMBER}",
  "has_pr": false
}
EOF
    exit 0
  fi
  cd "$WORKTREE_PATH"
fi

# Get PR info - single batched API call with all needed fields
if [ -n "$PR_NUMBER" ]; then
  PR_DATA=$(gh pr view "$PR_NUMBER" --json number,title,state,mergeable,mergeStateStatus,reviewDecision,headRefName,baseRefName,additions,deletions,changedFiles,isDraft 2>/dev/null || echo '{}')
else
  PR_DATA=$(gh pr view --json number,title,state,mergeable,mergeStateStatus,reviewDecision,headRefName,baseRefName,additions,deletions,changedFiles,isDraft 2>/dev/null || echo '{}')
fi

# Check if PR exists
if [ -z "$PR_DATA" ] || [ "$PR_DATA" = "{}" ]; then
  cat <<EOF
{
  "error": "no_pr_found",
  "message": "No PR found for current branch",
  "suggestion": "Create a PR: gh pr create --base dev",
  "has_pr": false,
  "worktree_path": $([ -n "$WORKTREE_PATH" ] && echo "\"$WORKTREE_PATH\"" || echo "null")
}
EOF
  exit 0
fi

# Extract PR fields
PR_NUM=$(echo "$PR_DATA" | jq -r '.number')
PR_TITLE=$(echo "$PR_DATA" | jq -r '.title // empty')
PR_STATE=$(echo "$PR_DATA" | jq -r '.state // "UNKNOWN"')
MERGEABLE=$(echo "$PR_DATA" | jq -r '.mergeable // "UNKNOWN"')
MERGE_STATE=$(echo "$PR_DATA" | jq -r '.mergeStateStatus // "UNKNOWN"')
REVIEW_DECISION=$(echo "$PR_DATA" | jq -r '.reviewDecision // null')
HEAD_REF=$(echo "$PR_DATA" | jq -r '.headRefName // empty')
BASE_REF=$(echo "$PR_DATA" | jq -r '.baseRefName // "dev"')
ADDITIONS=$(echo "$PR_DATA" | jq -r '.additions // 0')
DELETIONS=$(echo "$PR_DATA" | jq -r '.deletions // 0')
CHANGED_FILES=$(echo "$PR_DATA" | jq -r '.changedFiles // 0')
IS_DRAFT=$(echo "$PR_DATA" | jq -r '.isDraft // false')

# Get CI checks - second API call
CHECKS_JSON=$(gh pr checks "$PR_NUM" --json name,state,conclusion 2>/dev/null || echo '[]')
CHECKS_PASSED=$(echo "$CHECKS_JSON" | jq '[.[] | select(.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")] | length')
CHECKS_FAILED=$(echo "$CHECKS_JSON" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT")] | length')
CHECKS_PENDING=$(echo "$CHECKS_JSON" | jq '[.[] | select(.state == "IN_PROGRESS" or .state == "QUEUED" or .state == "PENDING")] | length')
CHECKS_TOTAL=$(echo "$CHECKS_JSON" | jq 'length')

# Determine check status
if [ "$CHECKS_FAILED" -gt 0 ]; then
  CHECK_STATUS="failing"
elif [ "$CHECKS_PENDING" -gt 0 ]; then
  CHECK_STATUS="pending"
elif [ "$CHECKS_TOTAL" -eq 0 ]; then
  CHECK_STATUS="no_checks"
else
  CHECK_STATUS="passing"
fi

# Read local pr-status.json if exists
STATUS_FILE="pr-status.json"
HAS_LOCAL_STATUS=false
REVIEW_STATUS="no-review"
ITERATION=0
BLOCKING_COUNT=0
WARNING_COUNT=0
REVIEWERS_RUN="[]"
LAST_REVIEWED="null"
BLOCKING_ISSUES="[]"

if [ -f "$STATUS_FILE" ]; then
  HAS_LOCAL_STATUS=true
  REVIEW_STATUS=$(jq -r '.review_state.status // "pending"' "$STATUS_FILE")
  ITERATION=$(jq -r '.review_state.iteration // 0' "$STATUS_FILE")
  BLOCKING_COUNT=$(jq '[.blocking_issues // [] | .[] | select(.status == "open" and .severity == "error")] | length' "$STATUS_FILE" 2>/dev/null || echo 0)
  WARNING_COUNT=$(jq '[.blocking_issues // [] | .[] | select(.status == "open" and .severity == "warning")] | length' "$STATUS_FILE" 2>/dev/null || echo 0)
  REVIEWERS_RUN=$(jq -c '.review_state.reviewers_run // []' "$STATUS_FILE")
  LAST_REVIEWED=$(jq -r '.review_state.last_reviewed // null' "$STATUS_FILE")
  # Get blocking issues (limit to first 10 for display)
  BLOCKING_ISSUES=$(jq -c '[.blocking_issues // [] | .[] | select(.status == "open")] | .[0:10]' "$STATUS_FILE" 2>/dev/null || echo '[]')
fi

# Determine lifecycle state
LIFECYCLE="unknown"
if [ "$PR_STATE" = "MERGED" ]; then
  LIFECYCLE="merged"
elif [ "$PR_STATE" = "CLOSED" ]; then
  LIFECYCLE="closed"
elif [ "$HAS_LOCAL_STATUS" = false ]; then
  LIFECYCLE="no-review"
elif [ "$REVIEW_STATUS" = "approved" ]; then
  LIFECYCLE="approved"
elif [ "$REVIEW_STATUS" = "needs-fixes" ] || [ "$BLOCKING_COUNT" -gt 0 ]; then
  LIFECYCLE="needs-fixes"
elif [ "$REVIEW_STATUS" = "pending" ]; then
  LIFECYCLE="in-review"
else
  LIFECYCLE="no-review"
fi

# Determine recommended action
RECOMMENDED_ACTION=""
case $LIFECYCLE in
  "no-review")
    RECOMMENDED_ACTION="Run /pr-review-internal to start review"
    ;;
  "in-review")
    RECOMMENDED_ACTION="Wait for review to complete"
    ;;
  "needs-fixes")
    RECOMMENDED_ACTION="Run /pr-fix to address blocking issues"
    ;;
  "approved")
    if [ "$CHECK_STATUS" = "passing" ] && [ "$MERGEABLE" = "MERGEABLE" ]; then
      RECOMMENDED_ACTION="Merge the PR: gh pr merge --squash --delete-branch"
    elif [ "$CHECK_STATUS" = "pending" ]; then
      RECOMMENDED_ACTION="Wait for CI checks to complete"
    elif [ "$CHECK_STATUS" = "failing" ]; then
      RECOMMENDED_ACTION="Fix failing CI checks"
    elif [ "$MERGEABLE" = "CONFLICTING" ]; then
      RECOMMENDED_ACTION="Resolve merge conflicts"
    else
      RECOMMENDED_ACTION="Review PR state before merging"
    fi
    ;;
  "merged")
    RECOMMENDED_ACTION="PR already merged"
    ;;
  "closed")
    RECOMMENDED_ACTION="PR is closed - reopen if needed"
    ;;
esac

# Output structured JSON
cat <<EOF
{
  "has_pr": true,
  "pr": {
    "number": $PR_NUM,
    "title": $(echo "$PR_TITLE" | jq -Rs '.'),
    "state": "$PR_STATE",
    "is_draft": $IS_DRAFT,
    "head_ref": "$HEAD_REF",
    "base_ref": "$BASE_REF",
    "additions": $ADDITIONS,
    "deletions": $DELETIONS,
    "changed_files": $CHANGED_FILES
  },
  "github_state": {
    "mergeable": "$MERGEABLE",
    "merge_state": "$MERGE_STATE",
    "review_decision": $([ "$REVIEW_DECISION" = "null" ] && echo "null" || echo "\"$REVIEW_DECISION\"")
  },
  "checks": {
    "status": "$CHECK_STATUS",
    "passed": $CHECKS_PASSED,
    "failed": $CHECKS_FAILED,
    "pending": $CHECKS_PENDING,
    "total": $CHECKS_TOTAL
  },
  "review_status": {
    "lifecycle": "$LIFECYCLE",
    "status": "$REVIEW_STATUS",
    "iteration": $ITERATION,
    "blocking_count": $BLOCKING_COUNT,
    "warning_count": $WARNING_COUNT,
    "reviewers_run": $REVIEWERS_RUN,
    "last_reviewed": $([ "$LAST_REVIEWED" = "null" ] && echo "null" || echo "\"$LAST_REVIEWED\"")
  },
  "blocking_issues": $BLOCKING_ISSUES,
  "status_file": {
    "exists": $HAS_LOCAL_STATUS,
    "path": "$STATUS_FILE"
  },
  "worktree_path": $([ -n "$WORKTREE_PATH" ] && echo "\"$WORKTREE_PATH\"" || echo "null"),
  "recommended_action": "$RECOMMENDED_ACTION",
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
