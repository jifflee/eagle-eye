#!/bin/bash
set -euo pipefail
# worktree-validate-close.sh
# Validates that a worktree is safe to close (no unpushed work)
#
# DESCRIPTION:
#   Checks if a worktree exists for an issue and whether it has unpushed
#   commits or uncommitted changes. Returns validation status with
#   recommendations for handling any issues found.
#
# USAGE:
#   ./scripts/worktree-validate-close.sh <issue_number>
#   ./scripts/worktree-validate-close.sh <issue_number> --force
#   ./scripts/worktree-validate-close.sh <issue_number> --json
#
# FLAGS:
#   --force    Bypass validation and return success (caller acknowledges data loss)
#   --json     Output JSON format (default is text for human readability)
#
# EXIT CODES:
#   0 - Safe to close (no worktree or worktree is clean)
#   1 - Validation failed (unpushed work exists)
#   2 - Usage error
#
# OUTPUT (JSON):
#   {
#     "safe_to_close": true|false,
#     "issue": <number>,
#     "worktree_exists": true|false,
#     "worktree_path": "<path>",
#     "uncommitted_files": <count>,
#     "unpushed_commits": <count>,
#     "risk_level": "NONE"|"LOW"|"MED"|"HIGH",
#     "recommendation": "<action>",
#     "message": "<human readable message>",
#     "forced": true|false
#   }

set -e

# DEPRECATION NOTICE: Worktree scripts are being phased out in favor of container-based
# execution. See docs/CONTAINERIZED_WORKFLOW.md#worktree-deprecation-timeline for timeline.
# Containers push all work before exit, making close validation unnecessary.
echo "DEPRECATION: worktree-validate-close.sh will be removed in Phase 3. Use container mode instead." >&2

# Parse arguments
ISSUE_NUM=""
FORCE=false
JSON_OUTPUT=false

for arg in "$@"; do
  case "$arg" in
    --force)
      FORCE=true
      ;;
    --json)
      JSON_OUTPUT=true
      ;;
    [0-9]*)
      ISSUE_NUM="$arg"
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 <issue_number> [--force] [--json]" >&2
      exit 2
      ;;
  esac
done

if [ -z "$ISSUE_NUM" ]; then
  echo "Error: Issue number required" >&2
  echo "Usage: $0 <issue_number> [--force] [--json]" >&2
  exit 2
fi

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REPO_NAME=$(basename "$REPO_ROOT")
REPO_NAME=$(echo "$REPO_NAME" | sed 's/-issue-[0-9]*$//')
PARENT_DIR=$(dirname "$REPO_ROOT")
WORKTREE_PATH="$PARENT_DIR/${REPO_NAME}-issue-${ISSUE_NUM}"

# Helper function to output result
output_result() {
  local safe_to_close="$1"
  local worktree_exists="$2"
  local worktree_path="$3"
  local uncommitted="$4"
  local unpushed="$5"
  local risk_level="$6"
  local recommendation="$7"
  local message="$8"
  local forced="$9"

  if [ "$JSON_OUTPUT" = true ]; then
    jq -n \
      --argjson safe "$safe_to_close" \
      --argjson issue "$ISSUE_NUM" \
      --argjson wt_exists "$worktree_exists" \
      --arg path "$worktree_path" \
      --argjson uncommitted "$uncommitted" \
      --argjson unpushed "$unpushed" \
      --arg risk "$risk_level" \
      --arg rec "$recommendation" \
      --arg msg "$message" \
      --argjson forced "$forced" \
      '{
        safe_to_close: $safe,
        issue: $issue,
        worktree_exists: $wt_exists,
        worktree_path: $path,
        uncommitted_files: $uncommitted,
        unpushed_commits: $unpushed,
        risk_level: $risk,
        recommendation: $rec,
        message: $msg,
        forced: $forced
      }'
  else
    if [ "$safe_to_close" = true ]; then
      echo "✓ Issue #$ISSUE_NUM is safe to close"
      [ -n "$message" ] && echo "  $message"
    else
      echo "✗ Issue #$ISSUE_NUM has unpushed work"
      echo ""
      [ "$uncommitted" -gt 0 ] && echo "  Uncommitted files: $uncommitted"
      [ "$unpushed" -gt 0 ] && echo "  Unpushed commits: $unpushed"
      echo ""
      echo "  Risk level: $risk_level"
      echo "  Recommendation: $recommendation"
      echo ""
      echo "  $message"
    fi
  fi

  if [ "$safe_to_close" = true ]; then
    exit 0
  else
    exit 1
  fi
}

# Check if worktree exists
if [ ! -d "$WORKTREE_PATH" ]; then
  output_result true false "" 0 0 "NONE" "none" "No worktree exists for this issue" false
fi

# Worktree exists - check for unpushed work
UNCOMMITTED_COUNT=0
UNPUSHED_COUNT=0

# Check for uncommitted changes
if [ -d "$WORKTREE_PATH" ]; then
  UNCOMMITTED_COUNT=$(($(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | wc -l)))
fi

# Check for unpushed commits
if git -C "$WORKTREE_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  UNPUSHED_COUNT=$(($(git -C "$WORKTREE_PATH" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l)))
fi

# If force flag is set, return success with warning
if [ "$FORCE" = true ]; then
  output_result true true "$WORKTREE_PATH" "$UNCOMMITTED_COUNT" "$UNPUSHED_COUNT" \
    "FORCED" "force_close" \
    "Forced close - user acknowledged potential data loss" true
fi

# No unpushed work - safe to close
if [ "$UNCOMMITTED_COUNT" -eq 0 ] && [ "$UNPUSHED_COUNT" -eq 0 ]; then
  output_result true true "$WORKTREE_PATH" 0 0 \
    "NONE" "none" \
    "Worktree exists but all work is pushed" false
fi

# Determine risk level
RISK_LEVEL="LOW"
RECOMMENDATION="push"
MESSAGE="Push changes before closing issue"

if [ "$UNCOMMITTED_COUNT" -gt 0 ] && [ "$UNPUSHED_COUNT" -gt 0 ]; then
  RISK_LEVEL="HIGH"
  RECOMMENDATION="commit_and_push"
  MESSAGE="Commit changes and push before closing. Use --force to override."
elif [ "$UNCOMMITTED_COUNT" -gt 0 ]; then
  RISK_LEVEL="MED"
  RECOMMENDATION="commit_and_push"
  MESSAGE="Commit and push uncommitted changes. Use --force to override."
elif [ "$UNPUSHED_COUNT" -gt 10 ]; then
  RISK_LEVEL="HIGH"
  RECOMMENDATION="push"
  MESSAGE="Significant unpushed work ($UNPUSHED_COUNT commits). Use --force to override."
elif [ "$UNPUSHED_COUNT" -gt 0 ]; then
  RISK_LEVEL="MED"
  RECOMMENDATION="push"
  MESSAGE="Push $UNPUSHED_COUNT unpushed commit(s). Use --force to override."
fi

# Use classify-worktree-commits if available for more context
if [ -x "$SCRIPT_DIR/classify-worktree-commits.sh" ]; then
  CLASSIFICATION=$("$SCRIPT_DIR/classify-worktree-commits.sh" "$ISSUE_NUM" 2>/dev/null || echo "")
  if [ -n "$CLASSIFICATION" ] && [ "$(echo "$CLASSIFICATION" | jq -r '.success // false')" = "true" ]; then
    PR_MERGED=$(echo "$CLASSIFICATION" | jq -r '.pr_merged // false')
    MERGED_COUNT=$(echo "$CLASSIFICATION" | jq -r '.summary.merged // 0')
    POST_MERGE_COUNT=$(echo "$CLASSIFICATION" | jq -r '.summary.post_merge // 0')

    if [ "$PR_MERGED" = "true" ] && [ "$POST_MERGE_COUNT" -eq 0 ] && [ "$MERGED_COUNT" -eq "$UNPUSHED_COUNT" ]; then
      # All unpushed commits were in the merged PR - safe to close
      output_result true true "$WORKTREE_PATH" "$UNCOMMITTED_COUNT" "$UNPUSHED_COUNT" \
        "LOW" "none" \
        "Worktree has unpushed commits but all were in the merged PR" false
    elif [ "$PR_MERGED" = "true" ] && [ "$POST_MERGE_COUNT" -gt 0 ]; then
      # Post-merge commits exist - HIGH RISK
      RISK_LEVEL="HIGH"
      RECOMMENDATION="cherry_pick_or_push"
      MESSAGE="$POST_MERGE_COUNT post-merge commit(s) not in merged PR. Cherry-pick to new branch or use --force."
    fi
  fi
fi

output_result false true "$WORKTREE_PATH" "$UNCOMMITTED_COUNT" "$UNPUSHED_COUNT" \
  "$RISK_LEVEL" "$RECOMMENDATION" "$MESSAGE" false
