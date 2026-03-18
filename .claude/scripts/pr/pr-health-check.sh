#!/usr/bin/env bash
# pr-health-check.sh - Analyze PR health without modifying anything
# Usage: ./scripts/pr-health-check.sh <PR#>

set -euo pipefail

# Check if PR number is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <PR#>" >&2
    exit 1
fi

PR_NUMBER="$1"

# Validate PR number is numeric
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: PR number must be numeric" >&2
    exit 1
fi

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed" >&2
    exit 1
fi

# Fetch PR information
PR_DATA=$(gh pr view "$PR_NUMBER" --json number,state,baseRefName,headRefName,mergeable,commits 2>/dev/null || {
    echo "Error: Failed to fetch PR #$PR_NUMBER" >&2
    exit 1
})

# Check if PR is closed
PR_STATE=$(echo "$PR_DATA" | jq -r '.state')
if [ "$PR_STATE" != "OPEN" ]; then
    echo "{\"error\": \"PR #$PR_NUMBER is not open (state: $PR_STATE)\"}" | jq '.'
    exit 1
fi

# Extract PR details
BASE_BRANCH=$(echo "$PR_DATA" | jq -r '.baseRefName')
HEAD_BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')
MERGEABLE=$(echo "$PR_DATA" | jq -r '.mergeable')
COMMITS_TOTAL=$(echo "$PR_DATA" | jq '.commits | length')

# Fetch current repo to ensure we have latest refs
git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true
git fetch origin "$HEAD_BRANCH" --quiet 2>/dev/null || true

# Get commit count behind base branch
COMMITS_BEHIND_BASE=$(git rev-list --count "origin/$HEAD_BRANCH..origin/$BASE_BRANCH" 2>/dev/null || echo "0")

# Count commits already in base branch (upstream)
# This checks how many commits from the PR branch are already merged into base
COMMITS_UPSTREAM=0
if [ "$COMMITS_TOTAL" -gt 0 ]; then
    # Get all commits in PR branch that are not in base branch
    UNIQUE_COMMITS=$(git rev-list --count "origin/$BASE_BRANCH..origin/$HEAD_BRANCH" 2>/dev/null || echo "$COMMITS_TOTAL")
    # Calculate how many are already upstream
    COMMITS_UPSTREAM=$((COMMITS_TOTAL - UNIQUE_COMMITS))
fi

# Determine if there are conflicts
HAS_CONFLICTS=false
if [ "$MERGEABLE" = "CONFLICTING" ]; then
    HAS_CONFLICTS=true
fi

# Determine status and recommendation
STATUS="READY"
RECOMMENDED_ACTION="merge"
REASON="PR is ready to merge"

if [ "$COMMITS_UPSTREAM" -eq "$COMMITS_TOTAL" ] && [ "$COMMITS_TOTAL" -gt 0 ]; then
    STATUS="STALE"
    RECOMMENDED_ACTION="close"
    REASON="All commits already in base branch"
elif [ "$HAS_CONFLICTS" = "true" ]; then
    STATUS="CONFLICTING"
    RECOMMENDED_ACTION="rebase"
    REASON="Has merge conflicts that need resolution"
elif [ "$COMMITS_BEHIND_BASE" -gt 0 ]; then
    STATUS="NEEDS_REBASE"
    RECOMMENDED_ACTION="rebase"
    REASON="Branch is behind base by $COMMITS_BEHIND_BASE commit(s)"
elif [ "$MERGEABLE" = "CONFLICTING" ]; then
    STATUS="CONFLICTING"
    RECOMMENDED_ACTION="rebase"
    REASON="Has merge conflicts"
else
    # Check for required status checks
    CHECKS_STATUS=$(gh pr checks "$PR_NUMBER" --json state 2>/dev/null || echo "[]")
    FAILED_CHECKS=$(echo "$CHECKS_STATUS" | jq '[.[] | select(.state == "FAILURE" or .state == "ERROR")] | length')

    if [ "$FAILED_CHECKS" -gt 0 ]; then
        STATUS="BLOCKED"
        RECOMMENDED_ACTION="fix"
        REASON="Required checks failing ($FAILED_CHECKS check(s))"
    fi
fi

# Output JSON
cat <<EOF | jq '.'
{
  "pr_number": $PR_NUMBER,
  "status": "$STATUS",
  "commits_total": $COMMITS_TOTAL,
  "commits_upstream": $COMMITS_UPSTREAM,
  "commits_behind_base": $COMMITS_BEHIND_BASE,
  "has_conflicts": $HAS_CONFLICTS,
  "recommended_action": "$RECOMMENDED_ACTION",
  "reason": "$REASON"
}
EOF
