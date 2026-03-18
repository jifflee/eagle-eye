#!/usr/bin/env bash
set -euo pipefail

# batch-merge.sh - Merge multiple PRs sequentially with retry logic
# Usage: ./batch-merge.sh <pr1,pr2,pr3> or ./batch-merge.sh pr1 pr2 pr3

if [[ $# -eq 0 ]]; then
    echo "Error: PR numbers required"
    echo "Usage: $0 <pr1,pr2,pr3> or $0 pr1 pr2 pr3"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse PR list (handle both comma-separated and space-separated)
if [[ $# -eq 1 ]] && [[ "$1" == *","* ]]; then
    IFS=',' read -ra PR_LIST <<< "$1"
else
    PR_LIST=("$@")
fi

echo "🚀 Batch merge for ${#PR_LIST[@]} PR(s)..."
echo ""

# Step 1: Validate all PRs first
echo "📋 Step 1: Validating all PRs..."
VALID_PRS=()
INVALID_PRS=()

for PR in "${PR_LIST[@]}"; do
    PR=$(echo "$PR" | tr -d ' #')
    echo ""
    echo "Validating PR #$PR..."

    if "$SCRIPT_DIR/validate-merge.sh" "$PR" > /dev/null 2>&1; then
        echo "  ✅ PR #$PR is valid"
        VALID_PRS+=("$PR")
    else
        echo "  ❌ PR #$PR validation failed"
        INVALID_PRS+=("$PR")
    fi
done

echo ""
if [[ ${#INVALID_PRS[@]} -gt 0 ]]; then
    echo "⚠️  ${#INVALID_PRS[@]} PR(s) failed validation:"
    for PR in "${INVALID_PRS[@]}"; do
        echo "  - PR #$PR"
    done
    echo ""

    if [[ ${#VALID_PRS[@]} -eq 0 ]]; then
        echo "❌ No valid PRs to merge"
        exit 1
    fi

    read -p "Continue with ${#VALID_PRS[@]} valid PR(s)? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Aborted"
        exit 1
    fi
fi

echo ""
echo "📋 Step 2: Analyzing PR dependencies..."

# Get base refs for all PRs to detect dependencies
declare -A PR_BASE_REFS
declare -A PR_HEAD_REFS
declare -A PR_CREATED_AT

for PR in "${VALID_PRS[@]}"; do
    PR_DATA=$(gh pr view "$PR" --json headRefName,baseRefName,createdAt)
    PR_HEAD_REFS[$PR]=$(echo "$PR_DATA" | jq -r '.headRefName')
    PR_BASE_REFS[$PR]=$(echo "$PR_DATA" | jq -r '.baseRefName')
    PR_CREATED_AT[$PR]=$(echo "$PR_DATA" | jq -r '.createdAt')
done

# Sort PRs by creation time (oldest first) as a simple dependency heuristic
SORTED_PRS=($(for PR in "${VALID_PRS[@]}"; do
    echo "${PR_CREATED_AT[$PR]} $PR"
done | sort | cut -d' ' -f2))

echo "  Merge order (by creation date):"
for PR in "${SORTED_PRS[@]}"; do
    echo "    - PR #$PR (${PR_HEAD_REFS[$PR]} → ${PR_BASE_REFS[$PR]})"
done

echo ""
read -p "Proceed with batch merge? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Aborted"
    exit 1
fi

# Step 3: Merge all PRs sequentially
echo ""
echo "📋 Step 3: Merging PRs sequentially..."
echo ""

MERGED_PRS=()
FAILED_PRS=()

for PR in "${SORTED_PRS[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Merging PR #$PR..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if "$SCRIPT_DIR/merge-and-cleanup.sh" "$PR"; then
        echo ""
        echo "✅ PR #$PR merged successfully"
        MERGED_PRS+=("$PR")
    else
        echo ""
        echo "❌ PR #$PR merge failed"
        FAILED_PRS+=("$PR")

        # Ask whether to continue
        if [[ ${#SORTED_PRS[@]} -gt 1 ]]; then
            echo ""
            read -p "Continue with remaining PRs? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "❌ Batch merge aborted"
                break
            fi
        fi
    fi

    echo ""

    # Wait between merges to let GitHub stabilize
    if [[ "$PR" != "${SORTED_PRS[-1]}" ]]; then
        echo "Waiting 3s before next merge..."
        sleep 3
        echo ""
    fi
done

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Batch Merge Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Total PRs: ${#SORTED_PRS[@]}"
echo "Merged: ${#MERGED_PRS[@]}"
echo "Failed: ${#FAILED_PRS[@]}"

if [[ ${#MERGED_PRS[@]} -gt 0 ]]; then
    echo ""
    echo "✅ Merged PRs:"
    for PR in "${MERGED_PRS[@]}"; do
        echo "  - PR #$PR"
    done
fi

if [[ ${#FAILED_PRS[@]} -gt 0 ]]; then
    echo ""
    echo "❌ Failed PRs:"
    for PR in "${FAILED_PRS[@]}"; do
        echo "  - PR #$PR"
    done
    echo ""
    exit 1
fi

echo ""
echo "✅ Batch merge complete!"
echo ""

exit 0
