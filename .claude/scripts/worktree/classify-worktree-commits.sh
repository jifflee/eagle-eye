#!/bin/bash
set -euo pipefail
# classify-worktree-commits.sh
# Classifies worktree commits as pre-PR, post-PR, or unmerged
#
# DESCRIPTION:
#   Compares local commits against the merged PR to determine:
#   - MERGED: Commits that were part of the merged PR
#   - POST_MERGE: Commits made after PR was merged (new work)
#   - UNMERGED: Commits from branch with no merged PR
#
# USAGE:
#   ./scripts/classify-worktree-commits.sh <issue_number>
#
# OUTPUT:
#   JSON with classified commits and recommendations

set -e

ISSUE_NUM="$1"

if [ -z "$ISSUE_NUM" ]; then
  echo '{"success": false, "error": "Usage: classify-worktree-commits.sh <issue_number>"}' >&2
  exit 1
fi

# Setup paths
REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
REPO_NAME=$(echo "$REPO_NAME" | sed 's/-issue-[0-9]*$//')
WORKTREE_PATH=$(dirname "$(git rev-parse --show-toplevel)")/"${REPO_NAME}-issue-${ISSUE_NUM}"

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

# Get upstream tracking info
UPSTREAM=""
if git -C "$WORKTREE_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  UPSTREAM=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref '@{upstream}')
fi

# Check for unpushed commits (against upstream)
UNPUSHED_COMMITS=()
if [ -n "$UPSTREAM" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && UNPUSHED_COMMITS+=("$line")
  done < <(git -C "$WORKTREE_PATH" log --format="%H" '@{upstream}..HEAD' 2>/dev/null)
fi

UNPUSHED_COUNT=${#UNPUSHED_COMMITS[@]}

# If no unpushed commits, nothing to classify
if [ "$UNPUSHED_COUNT" -eq 0 ]; then
  jq -n \
    --arg issue "$ISSUE_NUM" \
    --arg branch "$BRANCH" \
    '{
      success: true,
      issue: $issue,
      branch: $branch,
      unpushed_count: 0,
      commits: [],
      summary: {
        merged: 0,
        post_merge: 0,
        unmerged: 0
      },
      recommendation: "clean",
      message: "No unpushed commits"
    }'
  exit 0
fi

# Check for merged PR
PR_INFO=$(gh pr list --head "$BRANCH" --state merged --json number,mergeCommit,mergedAt --limit 1 2>/dev/null || echo '[]')

if [ "$PR_INFO" = "[]" ] || [ -z "$PR_INFO" ] || [ "$PR_INFO" = "null" ]; then
  # No merged PR - all commits are unmerged
  COMMIT_DETAILS="[]"
  for sha in "${UNPUSHED_COMMITS[@]}"; do
    COMMIT_MSG=$(git -C "$WORKTREE_PATH" log -1 --format="%s" "$sha" 2>/dev/null | head -c 80 | tr -d '\n\r\t')
    COMMIT_DATE=$(git -C "$WORKTREE_PATH" log -1 --format="%ci" "$sha" 2>/dev/null)
    ENTRY=$(jq -n \
      --arg sha "$sha" \
      --arg short_sha "${sha:0:7}" \
      --arg message "$COMMIT_MSG" \
      --arg date "$COMMIT_DATE" \
      '{sha: $sha, short_sha: $short_sha, message: $message, date: $date, classification: "UNMERGED"}')
    COMMIT_DETAILS=$(echo "$COMMIT_DETAILS" | jq --argjson entry "$ENTRY" '. + [$entry]')
  done

  jq -n \
    --arg issue "$ISSUE_NUM" \
    --arg branch "$BRANCH" \
    --argjson count "$UNPUSHED_COUNT" \
    --argjson commits "$COMMIT_DETAILS" \
    '{
      success: true,
      issue: $issue,
      branch: $branch,
      pr_merged: false,
      unpushed_count: $count,
      commits: $commits,
      summary: {
        merged: 0,
        post_merge: 0,
        unmerged: $count
      },
      recommendation: "push_or_archive",
      message: "No PR merged - commits need to be pushed or archived"
    }'
  exit 0
fi

# PR was merged - get merge commit info
PR_NUMBER=$(echo "$PR_INFO" | jq -r '.[0].number // ""')
MERGE_COMMIT=$(echo "$PR_INFO" | jq -r '.[0].mergeCommit.oid // ""')
MERGED_AT=$(echo "$PR_INFO" | jq -r '.[0].mergedAt // ""')

if [ -z "$MERGE_COMMIT" ]; then
  # Cannot determine merge commit - treat as unmerged
  jq -n \
    --arg issue "$ISSUE_NUM" \
    --arg branch "$BRANCH" \
    --arg pr "$PR_NUMBER" \
    --argjson count "$UNPUSHED_COUNT" \
    '{
      success: true,
      issue: $issue,
      branch: $branch,
      pr_merged: true,
      pr_number: $pr,
      merge_commit: null,
      unpushed_count: $count,
      commits: [],
      summary: {
        merged: 0,
        post_merge: 0,
        unmerged: $count
      },
      recommendation: "review",
      message: "PR merged but cannot determine merge commit"
    }'
  exit 0
fi

# Fetch to ensure we have the merge commit
git -C "$WORKTREE_PATH" fetch origin 2>/dev/null || true

# Classify each unpushed commit
COMMIT_DETAILS="[]"
MERGED_COUNT=0
POST_MERGE_COUNT=0

for sha in "${UNPUSHED_COMMITS[@]}"; do
  COMMIT_MSG=$(git -C "$WORKTREE_PATH" log -1 --format="%s" "$sha" 2>/dev/null | head -c 80 | tr -d '\n\r\t')
  COMMIT_DATE=$(git -C "$WORKTREE_PATH" log -1 --format="%ci" "$sha" 2>/dev/null)

  # Check if commit is ancestor of merge commit (was included in PR)
  # or if it's a descendant (made after PR merge)
  CLASSIFICATION="POST_MERGE"

  # Check if this commit SHA exists in the merged branch
  # A commit is "MERGED" if it's an ancestor of the merge commit
  if git -C "$WORKTREE_PATH" merge-base --is-ancestor "$sha" "$MERGE_COMMIT" 2>/dev/null; then
    CLASSIFICATION="MERGED"
    ((MERGED_COUNT++))
  else
    # Check commit timestamp vs merge time
    COMMIT_TIMESTAMP=$(git -C "$WORKTREE_PATH" log -1 --format="%ct" "$sha" 2>/dev/null)
    MERGE_TIMESTAMP=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$MERGED_AT" "+%s" 2>/dev/null || date -d "$MERGED_AT" "+%s" 2>/dev/null || echo "0")

    if [ "$COMMIT_TIMESTAMP" -gt "$MERGE_TIMESTAMP" ] 2>/dev/null; then
      CLASSIFICATION="POST_MERGE"
      ((POST_MERGE_COUNT++))
    else
      # Commit is before merge but not an ancestor - diverged work
      CLASSIFICATION="POST_MERGE"
      ((POST_MERGE_COUNT++))
    fi
  fi

  ENTRY=$(jq -n \
    --arg sha "$sha" \
    --arg short_sha "${sha:0:7}" \
    --arg message "$COMMIT_MSG" \
    --arg date "$COMMIT_DATE" \
    --arg classification "$CLASSIFICATION" \
    '{sha: $sha, short_sha: $short_sha, message: $message, date: $date, classification: $classification}')
  COMMIT_DETAILS=$(echo "$COMMIT_DETAILS" | jq --argjson entry "$ENTRY" '. + [$entry]')
done

# Determine recommendation
RECOMMENDATION="review"
if [ "$POST_MERGE_COUNT" -gt 0 ]; then
  RECOMMENDATION="cherry_pick"
  MESSAGE="$POST_MERGE_COUNT commit(s) made after PR #$PR_NUMBER merged - consider cherry-picking to new branch"
elif [ "$MERGED_COUNT" -eq "$UNPUSHED_COUNT" ]; then
  RECOMMENDATION="discard"
  MESSAGE="All commits were included in merged PR #$PR_NUMBER - safe to discard"
else
  MESSAGE="Mixed commit state - review individually"
fi

jq -n \
  --arg issue "$ISSUE_NUM" \
  --arg branch "$BRANCH" \
  --arg pr "$PR_NUMBER" \
  --arg merge_commit "$MERGE_COMMIT" \
  --arg merged_at "$MERGED_AT" \
  --argjson count "$UNPUSHED_COUNT" \
  --argjson commits "$COMMIT_DETAILS" \
  --argjson merged "$MERGED_COUNT" \
  --argjson post_merge "$POST_MERGE_COUNT" \
  --arg recommendation "$RECOMMENDATION" \
  --arg message "$MESSAGE" \
  '{
    success: true,
    issue: $issue,
    branch: $branch,
    pr_merged: true,
    pr_number: $pr,
    merge_commit: $merge_commit,
    merged_at: $merged_at,
    unpushed_count: $count,
    commits: $commits,
    summary: {
      merged: $merged,
      post_merge: $post_merge,
      unmerged: 0
    },
    recommendation: $recommendation,
    message: $message
  }'
