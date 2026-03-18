#!/bin/bash
# check-rebase-status.sh
# Checks if current branch is rebased onto the target branch (default: origin/dev)
#
# Exit codes:
#   0 = Branch is rebased (up to date with target)
#   1 = Branch needs rebase (behind target)
#   2 = Error occurred
#
# JSON Output:
#   {
#     "rebased": true|false,
#     "current_branch": "feat/issue-N-*",
#     "target_branch": "origin/dev",
#     "commits_behind": 0,
#     "commits_ahead": 5,
#     "merge_base": "abc123",
#     "target_head": "def456",
#     "action": "ok|rebase_required|error"
#   }
#
# Usage:
#   ./scripts/check-rebase-status.sh              # Check against origin/dev
#   ./scripts/check-rebase-status.sh origin/main  # Check against origin/main
#   ./scripts/check-rebase-status.sh --auto-fix   # Auto-rebase if needed

set -e

TARGET_BRANCH="${1:-origin/dev}"
AUTO_FIX=""

# Parse flags
if [ "$1" = "--auto-fix" ]; then
  AUTO_FIX="true"
  TARGET_BRANCH="${2:-origin/dev}"
elif [ "$2" = "--auto-fix" ]; then
  AUTO_FIX="true"
fi

# Get current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "HEAD" ]; then
  echo '{"action": "error", "reason": "not_on_branch", "message": "Not on a branch (detached HEAD state)"}' >&2
  exit 2
fi

# Don't check protected branches
if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "dev" ]; then
  echo "{\"action\": \"ok\", \"rebased\": true, \"reason\": \"protected_branch\", \"current_branch\": \"$CURRENT_BRANCH\"}"
  exit 0
fi

# Fetch latest from origin (silent)
git fetch origin --quiet 2>/dev/null || {
  echo '{"action": "error", "reason": "fetch_failed", "message": "Could not fetch from origin"}' >&2
  exit 2
}

# Verify target branch exists
if ! git rev-parse "$TARGET_BRANCH" >/dev/null 2>&1; then
  echo "{\"action\": \"error\", \"reason\": \"target_not_found\", \"message\": \"Target branch $TARGET_BRANCH not found\"}" >&2
  exit 2
fi

# Get merge base (common ancestor)
MERGE_BASE=$(git merge-base "$CURRENT_BRANCH" "$TARGET_BRANCH" 2>/dev/null)
if [ -z "$MERGE_BASE" ]; then
  echo "{\"action\": \"error\", \"reason\": \"no_common_ancestor\", \"message\": \"No common ancestor with $TARGET_BRANCH\"}" >&2
  exit 2
fi

# Get target branch head
TARGET_HEAD=$(git rev-parse "$TARGET_BRANCH")

# Calculate commits ahead/behind
COMMITS_BEHIND=$(git rev-list --count "$MERGE_BASE".."$TARGET_HEAD" 2>/dev/null || echo "0")
COMMITS_AHEAD=$(git rev-list --count "$MERGE_BASE".."$CURRENT_BRANCH" 2>/dev/null || echo "0")

# Check if rebased: merge base should equal target head
if [ "$MERGE_BASE" = "$TARGET_HEAD" ]; then
  # Branch is rebased (up to date)
  echo "{\"action\": \"ok\", \"rebased\": true, \"current_branch\": \"$CURRENT_BRANCH\", \"target_branch\": \"$TARGET_BRANCH\", \"commits_behind\": 0, \"commits_ahead\": $COMMITS_AHEAD, \"merge_base\": \"${MERGE_BASE:0:7}\", \"target_head\": \"${TARGET_HEAD:0:7}\"}"
  exit 0
else
  # Branch needs rebase
  if [ "$AUTO_FIX" = "true" ]; then
    echo "" >&2
    echo "Attempting auto-rebase onto $TARGET_BRANCH..." >&2

    if git rebase "$TARGET_BRANCH" 2>&1; then
      # Rebase succeeded
      NEW_MERGE_BASE=$(git merge-base "$CURRENT_BRANCH" "$TARGET_BRANCH")
      echo "{\"action\": \"auto_fixed\", \"rebased\": true, \"current_branch\": \"$CURRENT_BRANCH\", \"target_branch\": \"$TARGET_BRANCH\", \"commits_behind\": 0, \"commits_ahead\": $COMMITS_AHEAD, \"message\": \"Auto-rebased successfully\"}"
      exit 0
    else
      # Rebase failed (conflicts)
      git rebase --abort 2>/dev/null || true
      CONFLICTING_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//')
      echo "{\"action\": \"rebase_failed\", \"rebased\": false, \"current_branch\": \"$CURRENT_BRANCH\", \"target_branch\": \"$TARGET_BRANCH\", \"commits_behind\": $COMMITS_BEHIND, \"reason\": \"conflicts\", \"message\": \"Rebase has conflicts. Manual resolution required.\"}" >&2
      exit 1
    fi
  else
    # Just report status
    echo "{\"action\": \"rebase_required\", \"rebased\": false, \"current_branch\": \"$CURRENT_BRANCH\", \"target_branch\": \"$TARGET_BRANCH\", \"commits_behind\": $COMMITS_BEHIND, \"commits_ahead\": $COMMITS_AHEAD, \"merge_base\": \"${MERGE_BASE:0:7}\", \"target_head\": \"${TARGET_HEAD:0:7}\"}"

    # Print human-readable warning to stderr
    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  REBASE REQUIRED                                              ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Branch '$CURRENT_BRANCH' is $COMMITS_BEHIND commit(s) behind $TARGET_BRANCH" >&2
    echo "║                                                               ║" >&2
    echo "║  Run: git fetch origin && git rebase $TARGET_BRANCH" >&2
    echo "║  Or:  ./scripts/check-rebase-status.sh --auto-fix             ║" >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
    exit 1
  fi
fi
