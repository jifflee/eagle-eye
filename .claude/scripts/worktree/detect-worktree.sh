#!/bin/bash
set -euo pipefail
# detect-worktree.sh
# Detects if current directory is a git worktree and returns status as JSON
#
# Usage: ./scripts/detect-worktree.sh
#
# Output: JSON object with worktree status

set -e

# Get git directory info
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || { echo '{"error": "Not in a git repository"}'; exit 1; }
GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null)
BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Get repo name
REPO_NAME=$(basename "$TOPLEVEL")

# Determine parent directory for worktrees
PARENT_DIR=$(dirname "$TOPLEVEL")

# Check if in worktree (worktrees have .git as a file, not a directory)
if [ -d "$TOPLEVEL/.git" ]; then
  IS_WORKTREE=false
  MAIN_REPO="$TOPLEVEL"
else
  IS_WORKTREE=true
  # Main repo is parent of git-common-dir (which points to main .git/worktrees/...)
  MAIN_REPO=$(cd "$GIT_COMMON" && git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$GIT_COMMON")")
fi

# List existing worktrees
WORKTREES=$(git worktree list --porcelain 2>/dev/null | grep "^worktree " | sed 's/^worktree //' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")

# Extract issue number from branch name if present
ISSUE_NUMBER=""
if [[ "$BRANCH" =~ issue-([0-9]+) ]]; then
  ISSUE_NUMBER="${BASH_REMATCH[1]}"
fi

# Build JSON output
cat << EOF
{
  "is_worktree": $IS_WORKTREE,
  "current_dir": "$TOPLEVEL",
  "main_repo": "$MAIN_REPO",
  "repo_name": "$REPO_NAME",
  "parent_dir": "$PARENT_DIR",
  "branch": "$BRANCH",
  "issue_number": "$ISSUE_NUMBER",
  "worktrees": $WORKTREES
}
EOF
