#!/bin/bash
set -euo pipefail
# sync-main-repo.sh
# Safely syncs the main repository to origin/main, origin/qa, or origin/dev
#
# Usage: ./scripts/sync-main-repo.sh [--dev] [--qa] [--check] [--force]
#
# Options:
#   --dev     Sync to origin/dev instead of origin/main
#   --qa      Sync to origin/qa instead of origin/main
#   --check   Just check status, don't sync
#   --force   Skip safety checks (uncommitted changes warning)
#
# Design: The main repo should NEVER have local changes - all work happens in worktrees.
# Therefore, reset-based sync is safe and preferred over merge-based pull.

set -e

TARGET_BRANCH="main"
CHECK_ONLY=false
FORCE=false

# Parse flags
for arg in "$@"; do
  case $arg in
    --dev) TARGET_BRANCH="dev" ;;
    --qa) TARGET_BRANCH="qa" ;;
    --check) CHECK_ONLY=true ;;
    --force) FORCE=true ;;
  esac
done

# Ensure we're in a git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo '{"error": "Not in a git repository"}'
  exit 1
fi

TOPLEVEL=$(git rev-parse --show-toplevel)
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Check if this is a worktree (worktrees have .git as file, not directory)
IS_WORKTREE=false
if [ ! -d "$TOPLEVEL/.git" ]; then
  IS_WORKTREE=true
fi

# Fetch latest from origin
git fetch origin --quiet

# Get ahead/behind counts
BEHIND=$(git rev-list HEAD..origin/$TARGET_BRANCH --count 2>/dev/null || echo 0)
AHEAD=$(git rev-list origin/$TARGET_BRANCH..HEAD --count 2>/dev/null || echo 0)

# Check for uncommitted changes
UNCOMMITTED_CHANGES=false
if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  UNCOMMITTED_CHANGES=true
fi

# Check for untracked files
UNTRACKED_COUNT=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')

# Build status JSON
if [ "$CHECK_ONLY" = true ]; then
  # Determine if current branch is an integration branch (dev or qa)
  # Integration branches are expected to be ahead of main - not a problem
  IS_INTEGRATION_BRANCH=false
  INTEGRATION_TYPE="none"
  if [ "$CURRENT_BRANCH" = "dev" ]; then
    IS_INTEGRATION_BRANCH=true
    INTEGRATION_TYPE="dev"
  elif [ "$CURRENT_BRANCH" = "qa" ]; then
    IS_INTEGRATION_BRANCH=true
    INTEGRATION_TYPE="qa"
  fi

  cat << EOF
{
  "current_branch": "$CURRENT_BRANCH",
  "target_branch": "origin/$TARGET_BRANCH",
  "is_worktree": $IS_WORKTREE,
  "is_integration_branch": $IS_INTEGRATION_BRANCH,
  "integration_type": "$INTEGRATION_TYPE",
  "behind_target": $BEHIND,
  "ahead_of_target": $AHEAD,
  "has_uncommitted_changes": $UNCOMMITTED_CHANGES,
  "untracked_files": $UNTRACKED_COUNT,
  "needs_sync": $([ "$BEHIND" -gt 0 ] && [ "$IS_INTEGRATION_BRANCH" = false ] && echo "true" || echo "false"),
  "is_diverged": $([ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ] && echo "true" || echo "false"),
  "recommendation": $(
    if [ "$IS_INTEGRATION_BRANCH" = true ]; then
      # dev/qa branches: being ahead of main is expected (work accumulates before release)
      if [ "$BEHIND" -gt 0 ]; then
        echo '"integration_branch_behind_main"'
      else
        echo '"integration_branch_ok"'
      fi
    elif [ "$BEHIND" -eq 0 ]; then
      echo '"up_to_date"'
    elif [ "$AHEAD" -gt 0 ]; then
      echo '"diverged_needs_reset"'
    elif [ "$UNCOMMITTED_CHANGES" = true ]; then
      echo '"has_local_changes"'
    else
      echo '"safe_to_sync"'
    fi
  )
}
EOF
  exit 0
fi

# Safety checks (skip with --force)
if [ "$IS_WORKTREE" = true ]; then
  echo "Error: This script should be run from the main repository, not a worktree."
  echo "Worktrees should remain on their feature branches."
  exit 1
fi

if [ "$UNCOMMITTED_CHANGES" = true ] && [ "$FORCE" = false ]; then
  echo "Error: You have uncommitted changes."
  echo "Since the main repo should not have local changes, either:"
  echo "  1. Discard them: git checkout -- ."
  echo "  2. Move work to a worktree"
  echo "  3. Use --force to proceed anyway"
  exit 1
fi

if [ "$UNTRACKED_COUNT" -gt 0 ] && [ "$FORCE" = false ]; then
  echo "Warning: You have $UNTRACKED_COUNT untracked file(s)."
  echo "These will NOT be affected by sync, but consider cleaning up."
fi

# Perform sync
if [ "$BEHIND" -eq 0 ]; then
  echo "Already up to date with origin/$TARGET_BRANCH."
  exit 0
fi

echo "Syncing to origin/$TARGET_BRANCH..."
echo "  Current branch: $CURRENT_BRANCH"
echo "  Behind by: $BEHIND commits"
if [ "$AHEAD" -gt 0 ]; then
  echo "  Ahead by: $AHEAD commits (will be discarded)"
fi

# If not on target branch, checkout first
if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
  echo "Switching to $TARGET_BRANCH branch..."
  git checkout "$TARGET_BRANCH" --quiet
fi

# Reset to origin
echo "Resetting to origin/$TARGET_BRANCH..."
git reset --hard "origin/$TARGET_BRANCH"

# Show result
NEW_HEAD=$(git rev-parse --short HEAD)
echo ""
echo "Sync complete!"
echo "  Now at: $NEW_HEAD"
echo "  Branch: $TARGET_BRANCH (tracking origin/$TARGET_BRANCH)"
