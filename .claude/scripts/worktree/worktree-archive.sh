#!/bin/bash
set -euo pipefail
# worktree-archive.sh
# Archives unpushed work to archive/* branches before cleanup
#
# DESCRIPTION:
#   Pushes local commits to archive/BRANCH_NAME on remote
#   Logs the archive operation for audit trail
#   Safe to run - preserves all local work before any destructive operation
#
# USAGE:
#   ./scripts/worktree-archive.sh <issue_number>
#   ./scripts/worktree-archive.sh <issue_number> --cleanup  # Archive AND cleanup worktree
#
# OUTPUT:
#   JSON with archive result

set -e

# DEPRECATION NOTICE: Worktree scripts are being phased out in favor of container-based
# execution. See docs/CONTAINERIZED_WORKFLOW.md#worktree-deprecation-timeline for timeline.
# Containers push all work before exit, eliminating the need for archive scripts.
echo "DEPRECATION: worktree-archive.sh will be removed in Phase 3. Use container mode instead." >&2

ISSUE_NUM="$1"
CLEANUP_AFTER="${2:-}"

if [ -z "$ISSUE_NUM" ]; then
  echo '{"success": false, "error": "Usage: worktree-archive.sh <issue_number> [--cleanup]"}' >&2
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
LOG_FILE="$LOG_DIR/archive.log"

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

# Count unpushed commits
UNPUSHED_COUNT=0
if git -C "$WORKTREE_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  UNPUSHED_COUNT=$(($(git -C "$WORKTREE_PATH" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l)))
fi

# Check for uncommitted changes
UNCOMMITTED_COUNT=$(($(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | wc -l)))

if [ "$UNCOMMITTED_COUNT" -gt 0 ]; then
  jq -n --argjson count "$UNCOMMITTED_COUNT" \
    '{"success": false, "error": "Has uncommitted changes. Commit first.", "uncommitted_files": $count}' >&2
  exit 1
fi

if [ "$UNPUSHED_COUNT" -eq 0 ]; then
  jq -n '{"success": true, "message": "No unpushed commits to archive", "archived": false, "commits": 0}'
  exit 0
fi

# Push to archive branch
ARCHIVE_BRANCH="archive/$BRANCH"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if git -C "$WORKTREE_PATH" push origin "$BRANCH:$ARCHIVE_BRANCH" 2>/dev/null; then
  # Log the archive operation
  echo "${TIMESTAMP}|archived|${ISSUE_NUM}|${BRANCH}|${ARCHIVE_BRANCH}|${UNPUSHED_COUNT} commits" >> "$LOG_FILE"

  RESULT_MSG="Archived $UNPUSHED_COUNT commits to $ARCHIVE_BRANCH"

  # Optionally cleanup after archiving
  if [ "$CLEANUP_AFTER" = "--cleanup" ]; then
    # Run worktree cleanup
    if [ -f "./scripts/worktree-cleanup.sh" ]; then
      ./scripts/worktree-cleanup.sh "$ISSUE_NUM" --delete-branch >/dev/null 2>&1 || true
      RESULT_MSG="$RESULT_MSG and cleaned up worktree"
      echo "${TIMESTAMP}|cleanup-after-archive|${ISSUE_NUM}|${BRANCH}|removed" >> "$LOG_FILE"
    fi
  fi

  jq -n \
    --arg issue "$ISSUE_NUM" \
    --arg branch "$BRANCH" \
    --arg archive_branch "$ARCHIVE_BRANCH" \
    --argjson commits "$UNPUSHED_COUNT" \
    --arg message "$RESULT_MSG" \
    --argjson cleaned_up "$([ "$CLEANUP_AFTER" = "--cleanup" ] && echo true || echo false)" \
    '{
      success: true,
      archived: true,
      issue: $issue,
      branch: $branch,
      archive_branch: $archive_branch,
      commits: $commits,
      message: $message,
      cleaned_up: $cleaned_up
    }'
else
  jq -n '{"success": false, "error": "Failed to push to archive branch"}' >&2
  exit 1
fi
