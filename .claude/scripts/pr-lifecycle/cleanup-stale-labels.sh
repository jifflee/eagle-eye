#!/usr/bin/env bash
set -euo pipefail

# cleanup-stale-labels.sh - Detect and remove stale wip:checked-out labels
# Usage: ./cleanup-stale-labels.sh [--dry-run]

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "🔍 Running in dry-run mode (no changes will be made)"
    echo ""
fi

echo "🔍 Scanning for stale wip:checked-out labels..."
echo ""

# Get all worktree branches
WORKTREE_BRANCHES=$(git worktree list --porcelain | grep "^branch" | cut -d' ' -f2 | sed 's|refs/heads/||' | sort)

if [[ -z "$WORKTREE_BRANCHES" ]]; then
    echo "ℹ️  No worktrees found"
    WORKTREE_BRANCHES=""
fi

# Get all issues with wip:checked-out label
LABELED_ISSUES=$(gh issue list --label "wip:checked-out" --json number,title,labels --limit 100)
ISSUE_COUNT=$(echo "$LABELED_ISSUES" | jq '. | length')

if [[ "$ISSUE_COUNT" -eq 0 ]]; then
    echo "✅ No issues with wip:checked-out label found"
    exit 0
fi

echo "Found $ISSUE_COUNT issue(s) with wip:checked-out label"
echo ""

STALE_COUNT=0
ACTIVE_COUNT=0

# Check each issue
echo "$LABELED_ISSUES" | jq -c '.[]' | while read -r issue; do
    ISSUE_NUMBER=$(echo "$issue" | jq -r '.number')
    ISSUE_TITLE=$(echo "$issue" | jq -r '.title')

    # Get associated PR if exists
    PR_DATA=$(gh pr list --search "linked:issue-$ISSUE_NUMBER" --json number,headRefName,state --limit 1)
    PR_COUNT=$(echo "$PR_DATA" | jq '. | length')

    IS_STALE=false
    REASON=""

    if [[ "$PR_COUNT" -gt 0 ]]; then
        PR_NUMBER=$(echo "$PR_DATA" | jq -r '.[0].number')
        PR_BRANCH=$(echo "$PR_DATA" | jq -r '.[0].headRefName')
        PR_STATE=$(echo "$PR_DATA" | jq -r '.[0].state')

        # Check if PR is merged/closed
        if [[ "$PR_STATE" == "MERGED" ]] || [[ "$PR_STATE" == "CLOSED" ]]; then
            IS_STALE=true
            REASON="PR #$PR_NUMBER is $PR_STATE"
        # Check if worktree exists for the branch
        elif ! echo "$WORKTREE_BRANCHES" | grep -q "^$PR_BRANCH$"; then
            IS_STALE=true
            REASON="No worktree for branch '$PR_BRANCH'"
        else
            ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
            echo "✓ Issue #$ISSUE_NUMBER - Active (worktree exists for $PR_BRANCH)"
        fi
    else
        # No PR found - label is stale
        IS_STALE=true
        REASON="No associated PR found"
    fi

    if [[ "$IS_STALE" == "true" ]]; then
        STALE_COUNT=$((STALE_COUNT + 1))
        echo "⚠️  Issue #$ISSUE_NUMBER - STALE ($REASON)"
        echo "    Title: $ISSUE_TITLE"

        if [[ "$DRY_RUN" == "false" ]]; then
            if gh issue edit "$ISSUE_NUMBER" --remove-label "wip:checked-out"; then
                echo "    ✅ Removed wip:checked-out label"
            else
                echo "    ❌ Failed to remove label"
            fi
        else
            echo "    [DRY-RUN] Would remove wip:checked-out label"
        fi
        echo ""
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total labeled issues: $ISSUE_COUNT"
echo "Active: $ACTIVE_COUNT"
echo "Stale: $STALE_COUNT"

if [[ "$DRY_RUN" == "true" ]] && [[ "$STALE_COUNT" -gt 0 ]]; then
    echo ""
    echo "ℹ️  Run without --dry-run to remove stale labels"
fi

echo ""

exit 0
