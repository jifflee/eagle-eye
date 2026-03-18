#!/usr/bin/env bash
set -euo pipefail

# merge-and-cleanup.sh - Safe merge with complete cleanup
# Usage: ./merge-and-cleanup.sh <pr_number>

PR_NUMBER="${1:-}"

if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: PR number required"
    echo "Usage: $0 <pr_number>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Starting merge and cleanup for PR #$PR_NUMBER..."
echo ""

# Step 1: Validate PR
echo "📋 Step 1/5: Validating PR..."
if ! "$SCRIPT_DIR/validate-merge.sh" "$PR_NUMBER"; then
    echo ""
    echo "❌ Validation failed - cannot proceed with merge"
    exit 1
fi
echo ""

# Get PR details for cleanup
PR_DATA=$(gh pr view "$PR_NUMBER" --json number,headRefName,baseRefName,body)
HEAD_REF=$(echo "$PR_DATA" | jq -r '.headRefName')
BASE_REF=$(echo "$PR_DATA" | jq -r '.baseRefName')
PR_BODY=$(echo "$PR_DATA" | jq -r '.body')

# Extract linked issue
LINKED_ISSUE=""
ISSUE_PATTERN='(Fixes|Closes|Resolves) #([0-9]+)'
if [[ "$PR_BODY" =~ $ISSUE_PATTERN ]]; then
    LINKED_ISSUE="${BASH_REMATCH[2]}"
fi

# Check if worktree exists
WORKTREE_PATH=$(git worktree list --porcelain | grep -A 2 "branch refs/heads/$HEAD_REF" | grep "worktree" | cut -d' ' -f2 || echo "")

# Step 2: Remove worktree first (if exists)
if [[ -n "$WORKTREE_PATH" ]]; then
    echo "📋 Step 2/5: Removing worktree..."
    echo "  Path: $WORKTREE_PATH"

    # Check if worktree is clean
    if [[ -d "$WORKTREE_PATH" ]]; then
        cd "$WORKTREE_PATH"
        if ! git diff --quiet || ! git diff --cached --quiet; then
            echo "⚠️  Worktree has uncommitted changes"
            git status --short
            read -p "Continue anyway? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "❌ Aborted"
                exit 1
            fi
        fi
        cd - > /dev/null
    fi

    git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
    echo "  ✅ Worktree removed"
else
    echo "📋 Step 2/5: No worktree to remove"
fi
echo ""

# Step 3: Merge PR with retry logic
echo "📋 Step 3/5: Merging PR..."

MAX_RETRIES=3
RETRY_COUNT=0
MERGE_SUCCESS=false

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    if [[ $RETRY_COUNT -gt 0 ]]; then
        echo "  Retry $RETRY_COUNT/$MAX_RETRIES (waiting 5s for base branch to stabilize)..."
        sleep 5
    fi

    # Attempt merge (squash by default)
    if gh pr merge "$PR_NUMBER" --squash --auto=false 2>&1 | tee /tmp/merge_output_$$.txt; then
        MERGE_SUCCESS=true
        break
    else
        MERGE_OUTPUT=$(cat /tmp/merge_output_$$.txt)

        # Check if it's a "base branch modified" error
        if echo "$MERGE_OUTPUT" | grep -q "Base branch was modified"; then
            echo "  ⚠️  Base branch was modified - will retry"
            RETRY_COUNT=$((RETRY_COUNT + 1))
        else
            echo "  ❌ Merge failed with unexpected error:"
            echo "$MERGE_OUTPUT"
            rm -f /tmp/merge_output_$$.txt
            exit 1
        fi
    fi
done

rm -f /tmp/merge_output_$$.txt

if [[ "$MERGE_SUCCESS" != "true" ]]; then
    echo "  ❌ Merge failed after $MAX_RETRIES retries"
    exit 1
fi

echo "  ✅ PR merged successfully"
echo ""

# Step 4: Close linked issue
if [[ -n "$LINKED_ISSUE" ]]; then
    echo "📋 Step 4/5: Closing linked issue #$LINKED_ISSUE..."

    # Check if issue is still open
    ISSUE_STATE=$(gh issue view "$LINKED_ISSUE" --json state --jq '.state' 2>/dev/null || echo "NOT_FOUND")

    if [[ "$ISSUE_STATE" == "OPEN" ]]; then
        gh issue close "$LINKED_ISSUE" --comment "Closed by PR #$PR_NUMBER"
        echo "  ✅ Issue #$LINKED_ISSUE closed"
    elif [[ "$ISSUE_STATE" == "CLOSED" ]]; then
        echo "  ℹ️  Issue #$LINKED_ISSUE already closed"
    else
        echo "  ⚠️  Issue #$LINKED_ISSUE not found"
    fi
else
    echo "📋 Step 4/5: No linked issue to close"
fi
echo ""

# Step 5: Clean up local branch
echo "📋 Step 5/5: Cleaning up local branch..."

# Switch to base branch if we're on the PR branch
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" == "$HEAD_REF" ]]; then
    git checkout "$BASE_REF"
fi

# Delete local branch if it exists
if git show-ref --verify --quiet "refs/heads/$HEAD_REF"; then
    git branch -D "$HEAD_REF" 2>/dev/null || true
    echo "  ✅ Local branch deleted"
else
    echo "  ℹ️  Local branch not found"
fi

# Delete remote branch (gh pr merge should handle this, but double-check)
if git ls-remote --heads origin "$HEAD_REF" | grep -q "$HEAD_REF"; then
    git push origin --delete "$HEAD_REF" 2>/dev/null || echo "  ℹ️  Remote branch already deleted"
else
    echo "  ℹ️  Remote branch already deleted"
fi

# Clean up any stale wip:checked-out labels
if [[ -n "$LINKED_ISSUE" ]]; then
    LABELS=$(gh issue view "$LINKED_ISSUE" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
    if echo "$LABELS" | grep -q "wip:checked-out"; then
        gh issue edit "$LINKED_ISSUE" --remove-label "wip:checked-out" 2>/dev/null || true
        echo "  ✅ Removed stale wip:checked-out label"
    fi
fi

echo ""
echo "✅ Merge and cleanup complete!"
echo "   PR #$PR_NUMBER merged into $BASE_REF"
if [[ -n "$LINKED_ISSUE" ]]; then
    echo "   Issue #$LINKED_ISSUE closed"
fi
echo ""

exit 0
