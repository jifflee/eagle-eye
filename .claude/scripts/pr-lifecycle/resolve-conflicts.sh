#!/usr/bin/env bash
set -euo pipefail

# resolve-conflicts.sh - Interactive conflict resolution helper
# Usage: ./resolve-conflicts.sh <pr_number>

PR_NUMBER="${1:-}"

if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: PR number required"
    echo "Usage: $0 <pr_number>"
    exit 1
fi

echo "🔧 Conflict Resolution Helper for PR #$PR_NUMBER"
echo ""

# Get PR details
PR_DATA=$(gh pr view "$PR_NUMBER" --json number,headRefName,baseRefName,mergeable,url)
HEAD_REF=$(echo "$PR_DATA" | jq -r '.headRefName')
BASE_REF=$(echo "$PR_DATA" | jq -r '.baseRefName')
MERGEABLE=$(echo "$PR_DATA" | jq -r '.mergeable')
PR_URL=$(echo "$PR_DATA" | jq -r '.url')

echo "Branch: $HEAD_REF → $BASE_REF"
echo "Status: $MERGEABLE"
echo "URL: $PR_URL"
echo ""

if [[ "$MERGEABLE" != "CONFLICTING" ]]; then
    echo "✅ PR has no conflicts"
    exit 0
fi

echo "📋 Conflict resolution steps:"
echo ""

# Check if worktree exists
WORKTREE_PATH=$(git worktree list --porcelain | grep -A 2 "branch refs/heads/$HEAD_REF" | grep "worktree" | cut -d' ' -f2 || echo "")

if [[ -z "$WORKTREE_PATH" ]]; then
    echo "ℹ️  No worktree found for branch $HEAD_REF"
    echo ""
    read -p "Create worktree for conflict resolution? (y/N) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        WORKTREE_PATH="$HOME/.worktrees/$(basename "$PWD")/pr-$PR_NUMBER"
        mkdir -p "$(dirname "$WORKTREE_PATH")"

        echo "Creating worktree at $WORKTREE_PATH..."
        git worktree add "$WORKTREE_PATH" "$HEAD_REF"
        echo "✅ Worktree created"
    else
        echo "❌ Cannot resolve conflicts without worktree"
        exit 1
    fi
fi

echo ""
echo "Worktree path: $WORKTREE_PATH"
echo ""

# Navigate to worktree
cd "$WORKTREE_PATH"

# Ensure we're on the right branch
git checkout "$HEAD_REF" 2>/dev/null || true

echo "Step 1: Fetching latest base branch..."
git fetch origin "$BASE_REF"
echo "✅ Fetched"
echo ""

echo "Step 2: Attempting rebase..."
echo ""

if git rebase "origin/$BASE_REF"; then
    echo ""
    echo "✅ Rebase successful - no conflicts!"
    echo ""

    read -p "Push rebased branch? (y/N) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Pushing..."
        git push --force-with-lease
        echo "✅ Pushed"
        echo ""
        echo "✅ Conflicts resolved! PR should now be mergeable."
    fi

    exit 0
else
    echo ""
    echo "⚠️  Conflicts detected during rebase"
    echo ""
    echo "Conflicting files:"
    git diff --name-only --diff-filter=U | while read -r file; do
        echo "  - $file"
    done
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📝 Manual Resolution Required"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "1. Resolve conflicts in your editor:"
    echo "   cd $WORKTREE_PATH"
    echo ""
    echo "2. Mark conflicts as resolved:"
    echo "   git add <resolved-files>"
    echo ""
    echo "3. Continue rebase:"
    echo "   git rebase --continue"
    echo ""
    echo "4. Push rebased branch:"
    echo "   git push --force-with-lease"
    echo ""
    echo "To abort rebase:"
    echo "   git rebase --abort"
    echo ""

    # Offer to open editor
    if command -v code &> /dev/null; then
        echo ""
        read -p "Open VS Code to resolve conflicts? (y/N) " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            code "$WORKTREE_PATH"
        fi
    fi

    exit 1
fi
