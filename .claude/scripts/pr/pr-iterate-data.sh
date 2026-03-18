#!/bin/bash
set -euo pipefail
# pr-iterate-data.sh
# Gathers PR and review state for iteration loop
# size-ok: single-purpose data script for pr-iterate skill
#
# Usage:
#   ./scripts/pr-iterate-data.sh              # Get current state
#   ./scripts/pr-iterate-data.sh --max 5      # Include max iterations
#
# Outputs structured JSON with PR info and review state

set -e

MAX_ITERATIONS=3

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --max)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Get PR info from current branch (single API call)
PR_DATA=$(gh pr view --json number,title,state,baseRefName,headRefName,mergeable,mergeStateStatus 2>/dev/null || echo '{}')

if [ -z "$PR_DATA" ] || [ "$PR_DATA" = "{}" ]; then
  cat <<EOF
{
  "error": "No PR found for current branch",
  "suggestion": "Create a PR first: gh pr create --base dev",
  "has_pr": false
}
EOF
  exit 0
fi

PR_NUMBER=$(echo "$PR_DATA" | jq -r '.number // empty')
PR_TITLE=$(echo "$PR_DATA" | jq -r '.title // empty')
PR_STATE=$(echo "$PR_DATA" | jq -r '.state // "UNKNOWN"')
BASE_REF=$(echo "$PR_DATA" | jq -r '.baseRefName // "dev"')
HEAD_REF=$(echo "$PR_DATA" | jq -r '.headRefName // empty')
MERGEABLE=$(echo "$PR_DATA" | jq -r '.mergeable // "UNKNOWN"')
MERGE_STATE=$(echo "$PR_DATA" | jq -r '.mergeStateStatus // "UNKNOWN"')

# Check for pr-status.json
STATUS_FILE="pr-status.json"
REVIEW_STATUS="pending"
ITERATION=0
BLOCKING_COUNT=0
REVIEWERS_RUN="[]"

if [ -f "$STATUS_FILE" ]; then
  REVIEW_STATUS=$(jq -r '.review_state.status // "pending"' "$STATUS_FILE")
  ITERATION=$(jq -r '.review_state.iteration // 0' "$STATUS_FILE")
  BLOCKING_COUNT=$(jq '[.blocking_issues[] | select(.status == "open")] | length' "$STATUS_FILE" 2>/dev/null || echo 0)
  REVIEWERS_RUN=$(jq -c '.review_state.reviewers_run // []' "$STATUS_FILE")
fi

# Check if we can continue iterating
CAN_ITERATE=true
STOP_REASON=""

if [ "$REVIEW_STATUS" = "approved" ]; then
  CAN_ITERATE=false
  STOP_REASON="already_approved"
elif [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  CAN_ITERATE=false
  STOP_REASON="max_iterations_reached"
elif [ "$PR_STATE" = "MERGED" ]; then
  CAN_ITERATE=false
  STOP_REASON="pr_already_merged"
elif [ "$PR_STATE" = "CLOSED" ]; then
  CAN_ITERATE=false
  STOP_REASON="pr_closed"
fi

# Output structured JSON
cat <<EOF
{
  "has_pr": true,
  "pr": {
    "number": $PR_NUMBER,
    "title": $(echo "$PR_TITLE" | jq -Rs '.'),
    "state": "$PR_STATE",
    "base_ref": "$BASE_REF",
    "head_ref": "$HEAD_REF",
    "mergeable": "$MERGEABLE",
    "merge_state": "$MERGE_STATE"
  },
  "review_state": {
    "status": "$REVIEW_STATUS",
    "iteration": $ITERATION,
    "blocking_issues": $BLOCKING_COUNT,
    "reviewers_run": $REVIEWERS_RUN
  },
  "iteration_config": {
    "max_iterations": $MAX_ITERATIONS,
    "current_iteration": $ITERATION,
    "remaining": $((MAX_ITERATIONS - ITERATION)),
    "can_iterate": $CAN_ITERATE,
    "stop_reason": $([ -n "$STOP_REASON" ] && echo "\"$STOP_REASON\"" || echo "null")
  },
  "status_file": {
    "exists": $([ -f "$STATUS_FILE" ] && echo "true" || echo "false"),
    "path": "$STATUS_FILE"
  },
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
