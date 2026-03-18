#!/usr/bin/env bash
set -euo pipefail

# validate-merge.sh - Pre-merge validation for PRs
# Usage: ./validate-merge.sh <pr_number>

PR_NUMBER="${1:-}"

if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: PR number required"
    echo "Usage: $0 <pr_number>"
    exit 1
fi

echo "🔍 Validating PR #$PR_NUMBER..."

# Get PR details
PR_DATA=$(gh pr view "$PR_NUMBER" --json number,title,state,mergeable,headRefName,baseRefName,body,url)

STATE=$(echo "$PR_DATA" | jq -r '.state')
MERGEABLE=$(echo "$PR_DATA" | jq -r '.mergeable')
HEAD_REF=$(echo "$PR_DATA" | jq -r '.headRefName')
BASE_REF=$(echo "$PR_DATA" | jq -r '.baseRefName')
PR_BODY=$(echo "$PR_DATA" | jq -r '.body')
PR_URL=$(echo "$PR_DATA" | jq -r '.url')

echo "  State: $STATE"
echo "  Mergeable: $MERGEABLE"
echo "  Branch: $HEAD_REF → $BASE_REF"

# Check PR is open
if [[ "$STATE" != "OPEN" ]]; then
    echo "❌ PR is not open (state: $STATE)"
    exit 1
fi

# Check mergeable status
if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
    echo "❌ PR has conflicts - manual resolution required"
    echo "   Run: ./scripts/pr-lifecycle/resolve-conflicts.sh $PR_NUMBER"
    exit 1
elif [[ "$MERGEABLE" == "UNKNOWN" ]]; then
    echo "⚠️  Mergeable status unknown - GitHub may still be computing"
fi

# Check for linked issue in PR body
ISSUE_PATTERN='(Fixes|Closes|Resolves) #([0-9]+)'
if [[ "$PR_BODY" =~ $ISSUE_PATTERN ]]; then
    LINKED_ISSUE="${BASH_REMATCH[2]}"
    echo "  Linked issue: #$LINKED_ISSUE"

    # Verify issue exists and is open
    ISSUE_STATE=$(gh issue view "$LINKED_ISSUE" --json state --jq '.state' 2>/dev/null || echo "NOT_FOUND")
    if [[ "$ISSUE_STATE" == "NOT_FOUND" ]]; then
        echo "⚠️  Linked issue #$LINKED_ISSUE not found"
    elif [[ "$ISSUE_STATE" == "CLOSED" ]]; then
        echo "⚠️  Linked issue #$LINKED_ISSUE already closed"
    else
        echo "  Issue #$LINKED_ISSUE is open"
    fi
else
    echo "⚠️  No linked issue found in PR body (expected 'Fixes #N')"
fi

# Check if branch is behind base
echo ""
echo "🔄 Checking for base branch drift..."

# Fetch latest
git fetch origin "$BASE_REF" --quiet
git fetch origin "$HEAD_REF" --quiet 2>/dev/null || true

# Check if head is behind base
BASE_SHA=$(git rev-parse "origin/$BASE_REF")
HEAD_SHA=$(git rev-parse "origin/$HEAD_REF" 2>/dev/null || git rev-parse "$HEAD_REF")

BEHIND_COUNT=$(git rev-list --count "$HEAD_SHA..$BASE_SHA" 2>/dev/null || echo "0")

if [[ "$BEHIND_COUNT" -gt 0 ]]; then
    echo "  Branch is $BEHIND_COUNT commit(s) behind $BASE_REF"

    # Check if auto-rebase is possible
    MERGE_BASE=$(git merge-base "$HEAD_SHA" "$BASE_SHA")
    CONFLICTS=$(git merge-tree "$MERGE_BASE" "$HEAD_SHA" "$BASE_SHA" | grep -c "^changed in both" || true)

    if [[ "$CONFLICTS" -gt 0 ]]; then
        echo "❌ Auto-rebase not possible - conflicts detected"
        echo "   Run: ./scripts/pr-lifecycle/resolve-conflicts.sh $PR_NUMBER"
        exit 1
    else
        echo "  ✅ Auto-rebase possible (no conflicts)"

        # Offer to rebase if requested
        if [[ "${AUTO_REBASE:-}" == "true" ]]; then
            echo ""
            echo "🔄 Auto-rebasing..."

            # Check if we have a worktree for this branch
            WORKTREE_PATH=$(git worktree list --porcelain | grep -A 2 "branch refs/heads/$HEAD_REF" | grep "worktree" | cut -d' ' -f2 || echo "")

            if [[ -n "$WORKTREE_PATH" ]]; then
                cd "$WORKTREE_PATH"
                git pull --rebase origin "$BASE_REF"
                git push --force-with-lease
                cd - > /dev/null
                echo "  ✅ Rebased and force-pushed"
            else
                echo "  ⚠️  No worktree found for branch - skipping rebase"
            fi
        else
            echo "  ℹ️  Run with AUTO_REBASE=true to auto-rebase"
        fi
    fi
else
    echo "  ✅ Branch is up to date with $BASE_REF"
fi

# Check CI status
echo ""
echo "🧪 Checking CI status..."
CI_STATUS=$(gh pr checks "$PR_NUMBER" --json state,name,conclusion)
FAILING_CHECKS=$(echo "$CI_STATUS" | jq -r '.[] | select(.conclusion == "FAILURE") | .name' | wc -l)
PENDING_CHECKS=$(echo "$CI_STATUS" | jq -r '.[] | select(.state == "PENDING" or .state == "IN_PROGRESS") | .name' | wc -l)

if [[ "$FAILING_CHECKS" -gt 0 ]]; then
    echo "❌ $FAILING_CHECKS failing check(s)"
    echo "$CI_STATUS" | jq -r '.[] | select(.conclusion == "FAILURE") | "  - \(.name)"'
    exit 1
elif [[ "$PENDING_CHECKS" -gt 0 ]]; then
    echo "⚠️  $PENDING_CHECKS check(s) still running"
    echo "$CI_STATUS" | jq -r '.[] | select(.state == "PENDING" or .state == "IN_PROGRESS") | "  - \(.name)"'
else
    echo "  ✅ All checks passed"
fi

echo ""
echo "✅ PR #$PR_NUMBER is ready to merge"
echo "   URL: $PR_URL"

exit 0
