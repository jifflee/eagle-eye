#!/bin/bash
set -euo pipefail
# worktree-safe-merge.sh
# Safely merges PRs regardless of worktree context
#
# Problem: `gh pr merge --delete-branch` fails in worktrees because it tries
# to update local git refs. When another worktree is tracking `dev`, git refuses.
#
# Solution: In worktrees, use GitHub API directly to avoid local git operations.
#
# Usage:
#   ./scripts/worktree-safe-merge.sh <PR_NUMBER> [--squash|--merge|--rebase]
#   ./scripts/worktree-safe-merge.sh <PR_NUMBER> --squash --delete-branch
#
# Examples:
#   ./scripts/worktree-safe-merge.sh 101 --squash
#   ./scripts/worktree-safe-merge.sh 101 --squash --delete-branch
#
# Output: JSON with merge result

set -e

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ DEPRECATION NOTICE (Phase 2 - Apr 2026)                                     │
# │                                                                             │
# │ This script is DEPRECATED and scheduled for removal in Phase 3 (H2 2026).  │
# │                                                                             │
# │ NOTE: Keep this script until container merge is proven stable.              │
# │       Standard `gh pr merge` works in containers without worktree conflicts.│
# │                                                                             │
# │ Replacements:                                                               │
# │   - Container mode: /sprint-work --issue N --container                     │
# │   - Direct merge:   gh pr merge --squash --delete-branch (in containers)   │
# │                                                                             │
# │ See: docs/CONTAINERIZED_WORKFLOW.md#worktree-deprecation-timeline          │
# └─────────────────────────────────────────────────────────────────────────────┘
echo "⚠️  DEPRECATED: worktree-safe-merge.sh → Use container mode for conflict-free merges" >&2

# Parse arguments
PR_NUMBER=""
MERGE_METHOD="squash"
DELETE_BRANCH=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --squash)
      MERGE_METHOD="squash"
      shift
      ;;
    --merge)
      MERGE_METHOD="merge"
      shift
      ;;
    --rebase)
      MERGE_METHOD="rebase"
      shift
      ;;
    --delete-branch)
      DELETE_BRANCH=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 <PR_NUMBER> [--squash|--merge|--rebase] [--delete-branch]"
      echo ""
      echo "Safely merges PRs regardless of worktree context."
      echo "In worktrees, uses GitHub API to avoid local git operations."
      echo ""
      echo "Options:"
      echo "  --squash         Squash and merge (default)"
      echo "  --merge          Create merge commit"
      echo "  --rebase         Rebase and merge"
      echo "  --delete-branch  Delete the branch after merge"
      exit 0
      ;;
    *)
      if [[ -z "$PR_NUMBER" && "$1" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$1"
      else
        echo "Error: Unknown argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  echo "Error: PR number required" >&2
  echo "Usage: $0 <PR_NUMBER> [--squash|--merge|--rebase] [--delete-branch]" >&2
  exit 1
fi

# Get repo info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || {
  echo '{"success": false, "error": "Could not determine repository"}' >&2
  exit 1
}

# Detect if in worktree
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo '{"success": false, "error": "Not in a git repository"}' >&2
  exit 1
}

if [ -d "$TOPLEVEL/.git" ]; then
  IS_WORKTREE=false
else
  IS_WORKTREE=true
fi

# Get PR details
PR_INFO=$(gh pr view "$PR_NUMBER" --json state,headRefName,mergeable 2>/dev/null) || {
  echo '{"success": false, "error": "Could not fetch PR #'"$PR_NUMBER"'"}' >&2
  exit 1
}

PR_STATE=$(echo "$PR_INFO" | jq -r '.state')
BRANCH_NAME=$(echo "$PR_INFO" | jq -r '.headRefName')
MERGEABLE=$(echo "$PR_INFO" | jq -r '.mergeable')

# Validate PR state
if [[ "$PR_STATE" != "OPEN" ]]; then
  echo '{"success": false, "error": "PR #'"$PR_NUMBER"' is not open (state: '"$PR_STATE"')"}' >&2
  exit 1
fi

if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
  echo '{"success": false, "error": "PR #'"$PR_NUMBER"' has merge conflicts"}' >&2
  exit 1
fi

# Perform merge based on context
if $IS_WORKTREE; then
  # In worktree: Use API-only merge to avoid local git operations
  echo "Merging PR #$PR_NUMBER via API (worktree-safe mode)..." >&2

  # Merge via API
  MERGE_RESULT=$(gh api -X PUT "repos/$REPO/pulls/$PR_NUMBER/merge" \
    -f merge_method="$MERGE_METHOD" \
    2>&1) || {
    ERROR_MSG=$(echo "$MERGE_RESULT" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "$MERGE_RESULT")
    echo '{"success": false, "error": "Merge failed: '"$ERROR_MSG"'", "worktree_mode": true}' >&2
    exit 1
  }

  SHA=$(echo "$MERGE_RESULT" | jq -r '.sha // "unknown"')

  # Delete branch if requested (via API to avoid local git operations)
  if $DELETE_BRANCH; then
    echo "Deleting remote branch '$BRANCH_NAME' via API..." >&2
    gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH_NAME" 2>/dev/null || {
      echo "Warning: Could not delete remote branch '$BRANCH_NAME'" >&2
    }
    BRANCH_DELETED=true
  else
    BRANCH_DELETED=false
  fi

  # Output success
  cat << EOF
{
  "success": true,
  "pr_number": $PR_NUMBER,
  "merge_method": "$MERGE_METHOD",
  "sha": "$SHA",
  "branch_deleted": $BRANCH_DELETED,
  "worktree_mode": true,
  "message": "PR #$PR_NUMBER merged successfully (worktree-safe API mode)"
}
EOF

else
  # Not in worktree: Use standard gh pr merge
  echo "Merging PR #$PR_NUMBER via gh CLI (standard mode)..." >&2

  MERGE_ARGS="--$MERGE_METHOD"
  if $DELETE_BRANCH; then
    MERGE_ARGS="$MERGE_ARGS --delete-branch"
  fi

  gh pr merge "$PR_NUMBER" $MERGE_ARGS || {
    echo '{"success": false, "error": "gh pr merge failed", "worktree_mode": false}' >&2
    exit 1
  }

  # Output success
  cat << EOF
{
  "success": true,
  "pr_number": $PR_NUMBER,
  "merge_method": "$MERGE_METHOD",
  "branch_deleted": $DELETE_BRANCH,
  "worktree_mode": false,
  "message": "PR #$PR_NUMBER merged successfully (standard mode)"
}
EOF

fi
