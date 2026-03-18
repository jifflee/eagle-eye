#!/bin/bash
set -euo pipefail
# worktree-discard.sh
# Safely discards worktrees for issues where PR was merged (LOW risk)
#
# DESCRIPTION:
#   Verifies PR was merged before allowing discard
#   Removes worktree and local branch
#   Logs the discard operation for audit trail
#
# USAGE:
#   ./scripts/worktree-discard.sh <issue_number>
#   ./scripts/worktree-discard.sh <issue_number> --force  # Skip PR merge check
#
# OUTPUT:
#   JSON with discard result

set -e

# DEPRECATION NOTICE: Worktree scripts are being phased out in favor of container-based
# execution. See docs/CONTAINERIZED_WORKFLOW.md#worktree-deprecation-timeline for timeline.
# Containers self-destruct on exit - no discard needed.
echo "DEPRECATION: worktree-discard.sh will be removed in Phase 3. Use container mode instead." >&2

ISSUE_NUM="$1"
FORCE="${2:-}"

if [ -z "$ISSUE_NUM" ]; then
  echo '{"success": false, "error": "Usage: worktree-discard.sh <issue_number> [--force]"}' >&2
  exit 1
fi

# Setup
REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
REPO_NAME=$(echo "$REPO_NAME" | sed 's/-issue-[0-9]*$//')
WORKTREE_PATH=$(dirname "$(git rev-parse --show-toplevel)")/"${REPO_NAME}-issue-${ISSUE_NUM}"

# Source framework config to get FRAMEWORK_LOG_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/framework-config.sh"

LOG_DIR="${FRAMEWORK_LOG_DIR}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/worktree-cleanup.log"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Verify worktree exists
if [ ! -d "$WORKTREE_PATH" ]; then
  jq -n --arg path "$WORKTREE_PATH" '{"success": false, "error": ("Worktree not found: " + $path)}' >&2
  exit 1
fi

# Get branch name
BRANCH=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  jq -n '{"success": false, "error": "Could not determine branch name"}' >&2
  exit 1
fi

# Check for uncommitted changes
UNCOMMITTED_COUNT=$(($(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | wc -l)))
if [ "$UNCOMMITTED_COUNT" -gt 0 ]; then
  jq -n --argjson count "$UNCOMMITTED_COUNT" \
    '{"success": false, "error": "Has uncommitted changes. Cannot discard.", "uncommitted_files": $count}' >&2
  exit 1
fi

# Count unpushed commits
UNPUSHED_COUNT=0
if git -C "$WORKTREE_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  UNPUSHED_COUNT=$(($(git -C "$WORKTREE_PATH" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l)))
fi

# Verify PR was merged (unless --force)
PR_MERGED="false"
PR_NUMBER=""
if [ "$FORCE" != "--force" ]; then
  PR_INFO=$(gh pr list --head "$BRANCH" --state merged --json number --limit 1 2>/dev/null || echo '[]')
  if [ "$PR_INFO" != "[]" ] && [ -n "$PR_INFO" ]; then
    PR_MERGED="true"
    PR_NUMBER=$(echo "$PR_INFO" | jq -r '.[0].number // ""')
  fi

  if [ "$PR_MERGED" != "true" ]; then
    jq -n \
      --arg issue "$ISSUE_NUM" \
      --arg branch "$BRANCH" \
      --argjson unpushed "$UNPUSHED_COUNT" \
      '{
        success: false,
        error: "PR not merged - use --force to discard anyway or use worktree-archive.sh first",
        issue: $issue,
        branch: $branch,
        unpushed_commits: $unpushed,
        risk: "HIGH"
      }' >&2
    exit 1
  fi
fi

# Perform the discard
# Safety check: verify worktree still exists before deletion
if [ ! -d "$WORKTREE_PATH" ]; then
  jq -n --arg path "$WORKTREE_PATH" \
    '{"success": false, "error": ("Worktree no longer exists: " + $path)}' >&2
  exit 1
fi

# Remove worktree
rm -rf "$WORKTREE_PATH"
git worktree prune 2>/dev/null || true

# Delete local branch
git branch -D "$BRANCH" 2>/dev/null || true

# Log the operation
echo "${TIMESTAMP}|discarded|${ISSUE_NUM}|${BRANCH}|${UNPUSHED_COUNT} unpushed|PR#${PR_NUMBER:-none}" >> "$LOG_FILE"

jq -n \
  --arg issue "$ISSUE_NUM" \
  --arg branch "$BRANCH" \
  --arg pr_number "$PR_NUMBER" \
  --argjson discarded_commits "$UNPUSHED_COUNT" \
  --argjson forced "$([ "$FORCE" = "--force" ] && echo true || echo false)" \
  '{
    success: true,
    issue: $issue,
    branch: $branch,
    discarded: true,
    discarded_commits: $discarded_commits,
    pr_merged: ($pr_number != ""),
    pr_number: (if $pr_number != "" then $pr_number else null end),
    forced: $forced,
    message: "Worktree and branch removed"
  }'
