#!/bin/bash
set -euo pipefail
# worktree-cherry-pick.sh
# Cherry-picks post-merge commits from a worktree to a new branch
#
# DESCRIPTION:
#   Takes commits identified as POST_MERGE by classify-worktree-commits.sh
#   and cherry-picks them to a new branch off dev
#
# USAGE:
#   ./scripts/worktree-cherry-pick.sh <issue_number> [--new-issue <new_issue_num>]
#   ./scripts/worktree-cherry-pick.sh <issue_number> --branch <branch_name>
#
# OPTIONS:
#   --new-issue <num>  Create branch feat/issue-<num> for cherry-picked commits
#   --branch <name>    Use specified branch name instead
#   --dry-run          Show what would be done without executing
#
# OUTPUT:
#   JSON with cherry-pick results

set -e

# DEPRECATION NOTICE: Worktree scripts are being phased out in favor of container-based
# execution. See docs/CONTAINERIZED_WORKFLOW.md#worktree-deprecation-timeline for timeline.
# Containers are ephemeral - no post-merge commits accumulate.
echo "DEPRECATION: worktree-cherry-pick.sh will be removed in Phase 3. Use container mode instead." >&2

ISSUE_NUM=""
NEW_ISSUE=""
TARGET_BRANCH=""
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --new-issue)
      NEW_ISSUE="$2"
      shift 2
      ;;
    --branch)
      TARGET_BRANCH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      if [ -z "$ISSUE_NUM" ]; then
        ISSUE_NUM="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$ISSUE_NUM" ]; then
  echo '{"success": false, "error": "Usage: worktree-cherry-pick.sh <issue_number> [--new-issue <num>] [--branch <name>] [--dry-run]"}' >&2
  exit 1
fi

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
REPO_NAME=$(echo "$REPO_NAME" | sed 's/-issue-[0-9]*$//')
WORKTREE_PATH=$(dirname "$(git rev-parse --show-toplevel)")/"${REPO_NAME}-issue-${ISSUE_NUM}"
MAIN_REPO=$(dirname "$(git rev-parse --show-toplevel)")/"${REPO_NAME}"

# Verify worktree exists
if [ ! -d "$WORKTREE_PATH" ]; then
  jq -n --arg path "$WORKTREE_PATH" '{"success": false, "error": ("Worktree not found: " + $path)}' >&2
  exit 1
fi

# Check if we're in main repo (required for branch creation)
if [ ! -d "$MAIN_REPO/.git" ]; then
  # We might BE the main repo
  if [ -d "$(git rev-parse --show-toplevel)/.git" ]; then
    MAIN_REPO=$(git rev-parse --show-toplevel)
  else
    jq -n '{"success": false, "error": "Must be able to access main repo for branch creation"}' >&2
    exit 1
  fi
fi

# Get classification of commits
CLASSIFICATION=$("$SCRIPT_DIR/classify-worktree-commits.sh" "$ISSUE_NUM" 2>/dev/null)

if [ "$(echo "$CLASSIFICATION" | jq -r '.success')" != "true" ]; then
  echo "$CLASSIFICATION" >&2
  exit 1
fi

# Extract post-merge commits
POST_MERGE_COMMITS=$(echo "$CLASSIFICATION" | jq '[.commits[] | select(.classification == "POST_MERGE")]')
POST_MERGE_COUNT=$(echo "$POST_MERGE_COMMITS" | jq 'length')

if [ "$POST_MERGE_COUNT" -eq 0 ]; then
  jq -n \
    --arg issue "$ISSUE_NUM" \
    '{
      success: true,
      issue: $issue,
      cherry_picked: false,
      commits_count: 0,
      message: "No post-merge commits to cherry-pick"
    }'
  exit 0
fi

# Determine target branch name
if [ -n "$TARGET_BRANCH" ]; then
  NEW_BRANCH="$TARGET_BRANCH"
elif [ -n "$NEW_ISSUE" ]; then
  NEW_BRANCH="feat/issue-$NEW_ISSUE"
else
  # Generate a branch name based on original issue with -followup suffix
  NEW_BRANCH="feat/issue-${ISSUE_NUM}-followup"
fi

# Get commit SHAs in reverse order (oldest first for cherry-pick)
COMMIT_SHAS=$(echo "$POST_MERGE_COMMITS" | jq -r '.[].sha' | tac)

if [ "$DRY_RUN" = true ]; then
  # Show what would be done
  jq -n \
    --arg issue "$ISSUE_NUM" \
    --arg new_branch "$NEW_BRANCH" \
    --argjson commits "$POST_MERGE_COMMITS" \
    --argjson count "$POST_MERGE_COUNT" \
    '{
      success: true,
      dry_run: true,
      issue: $issue,
      action: "cherry-pick",
      target_branch: $new_branch,
      base_branch: "dev",
      commits_to_pick: $commits,
      commits_count: $count,
      message: ("Would cherry-pick " + ($count | tostring) + " commit(s) to " + $new_branch)
    }'
  exit 0
fi

# Perform the cherry-pick
cd "$MAIN_REPO"

# Ensure we have latest dev
git fetch origin dev 2>/dev/null || true

# Create new branch from dev
if ! git checkout -b "$NEW_BRANCH" origin/dev 2>/dev/null; then
  jq -n \
    --arg branch "$NEW_BRANCH" \
    '{"success": false, "error": ("Failed to create branch: " + $branch)}' >&2
  exit 1
fi

# Cherry-pick each commit
PICKED_COMMITS=()
FAILED_COMMITS=()

for sha in $COMMIT_SHAS; do
  if git cherry-pick "$sha" 2>/dev/null; then
    PICKED_COMMITS+=("$sha")
  else
    # Cherry-pick failed - abort and record
    git cherry-pick --abort 2>/dev/null || true
    FAILED_COMMITS+=("$sha")
  fi
done

PICKED_COUNT=${#PICKED_COMMITS[@]}
FAILED_COUNT=${#FAILED_COMMITS[@]}

if [ "$FAILED_COUNT" -gt 0 ]; then
  # Some commits failed
  jq -n \
    --arg issue "$ISSUE_NUM" \
    --arg new_branch "$NEW_BRANCH" \
    --argjson picked "$PICKED_COUNT" \
    --argjson failed "$FAILED_COUNT" \
    --argjson total "$POST_MERGE_COUNT" \
    '{
      success: false,
      partial: true,
      issue: $issue,
      target_branch: $new_branch,
      picked_count: $picked,
      failed_count: $failed,
      total_count: $total,
      message: ("Cherry-picked " + ($picked | tostring) + "/" + ($total | tostring) + " commits. " + ($failed | tostring) + " failed (conflicts likely).")
    }'
  exit 1
fi

# Push the new branch
if git push -u origin "$NEW_BRANCH" 2>/dev/null; then
  PUSHED=true
else
  PUSHED=false
fi

# Log the operation
LOG_DIR="$HOME/.claude-tastic/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "${TIMESTAMP}|cherry-pick|${ISSUE_NUM}|${NEW_BRANCH}|${PICKED_COUNT} commits" >> "$LOG_DIR/worktree-cleanup.log"

jq -n \
  --arg issue "$ISSUE_NUM" \
  --arg new_branch "$NEW_BRANCH" \
  --argjson picked "$PICKED_COUNT" \
  --argjson pushed "$PUSHED" \
  --argjson commits "$POST_MERGE_COMMITS" \
  '{
    success: true,
    issue: $issue,
    cherry_picked: true,
    target_branch: $new_branch,
    base_branch: "dev",
    commits_count: $picked,
    pushed: $pushed,
    commits: $commits,
    message: ("Cherry-picked " + ($picked | tostring) + " commit(s) to " + $new_branch),
    next_steps: [
      ("Create issue for follow-up work if needed"),
      ("Create PR: gh pr create --base dev --head " + $new_branch),
      ("Clean up original worktree: ./scripts/worktree-cleanup.sh " + $issue)
    ]
  }'
