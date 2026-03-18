#!/bin/bash
# verify-pr-mergeable.sh
# Verifies that a PR is in a mergeable state before marking work as complete
#
# Usage:
#   ./scripts/verify-pr-mergeable.sh <pr_number>
#   ./scripts/verify-pr-mergeable.sh <pr_number> --json
#
# Exit codes:
#   0 - PR is mergeable
#   1 - PR is not mergeable
#   2 - Error (invalid PR, API failure, etc.)

set -euo pipefail

PR_NUMBER="${1:-}"
OUTPUT_FORMAT="${2:-text}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [[ -z "$PR_NUMBER" ]]; then
  echo "Usage: $0 <pr_number> [--json]"
  exit 2
fi

# Fetch PR mergeability data
PR_DATA=$(gh pr view "$PR_NUMBER" --json mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,isDraft 2>/dev/null) || {
  echo -e "${RED}❌ Failed to fetch PR #$PR_NUMBER${NC}"
  exit 2
}

# Parse fields
MERGEABLE=$(echo "$PR_DATA" | jq -r '.mergeable')
MERGE_STATE=$(echo "$PR_DATA" | jq -r '.mergeStateStatus')
REVIEW_DECISION=$(echo "$PR_DATA" | jq -r '.reviewDecision // "null"')
IS_DRAFT=$(echo "$PR_DATA" | jq -r '.isDraft')

# Determine lifecycle state
LIFECYCLE_STATE="unknown"
ACTION_NEEDED=""

if [[ "$IS_DRAFT" == "true" ]]; then
  LIFECYCLE_STATE="draft"
  ACTION_NEEDED="Mark as ready for review"
elif [[ "$MERGEABLE" == "CONFLICTING" ]]; then
  LIFECYCLE_STATE="blocked"
  ACTION_NEEDED="Resolve merge conflicts"
elif [[ "$MERGE_STATE" == "UNSTABLE" ]]; then
  LIFECYCLE_STATE="unstable"
  ACTION_NEEDED="Fix failing CI checks"
elif [[ "$MERGE_STATE" == "BEHIND" ]]; then
  LIFECYCLE_STATE="behind"
  ACTION_NEEDED="Update branch from base"
elif [[ "$REVIEW_DECISION" == "CHANGES_REQUESTED" ]]; then
  LIFECYCLE_STATE="blocked"
  ACTION_NEEDED="Address review feedback"
elif [[ "$MERGEABLE" == "MERGEABLE" ]] && [[ "$MERGE_STATE" == "CLEAN" ]]; then
  LIFECYCLE_STATE="ready"
  ACTION_NEEDED="Ready to merge"
elif [[ "$MERGEABLE" == "UNKNOWN" ]] || [[ "$MERGE_STATE" == "UNKNOWN" ]]; then
  LIFECYCLE_STATE="unknown"
  ACTION_NEEDED="Wait for GitHub to calculate mergeability"
else
  LIFECYCLE_STATE="open"
  ACTION_NEEDED="Under review"
fi

# Determine if mergeable
IS_MERGEABLE=false
if [[ "$LIFECYCLE_STATE" == "ready" ]]; then
  IS_MERGEABLE=true
fi

# Output based on format
if [[ "$OUTPUT_FORMAT" == "--json" ]]; then
  # JSON output
  cat <<EOF
{
  "pr_number": $PR_NUMBER,
  "mergeable": "$MERGEABLE",
  "merge_state": "$MERGE_STATE",
  "review_decision": "$REVIEW_DECISION",
  "is_draft": $IS_DRAFT,
  "lifecycle_state": "$LIFECYCLE_STATE",
  "action_needed": "$ACTION_NEEDED",
  "is_mergeable": $IS_MERGEABLE
}
EOF
else
  # Human-readable output
  echo ""
  echo "PR #$PR_NUMBER Mergeability Check"
  echo "=================================="
  echo ""
  echo "Mergeable:       $MERGEABLE"
  echo "Merge State:     $MERGE_STATE"
  echo "Review Status:   $REVIEW_DECISION"
  echo "Is Draft:        $IS_DRAFT"
  echo ""
  echo "Lifecycle State: $LIFECYCLE_STATE"
  echo "Action Needed:   $ACTION_NEEDED"
  echo ""

  if [[ "$IS_MERGEABLE" == "true" ]]; then
    echo -e "${GREEN}✅ PR #$PR_NUMBER is MERGEABLE${NC}"
    echo ""
    echo "Work can be marked as complete."
    exit 0
  else
    echo -e "${RED}❌ PR #$PR_NUMBER is NOT mergeable${NC}"
    echo ""
    echo "Resolution required:"
    echo ""

    case "$LIFECYCLE_STATE" in
      draft)
        echo "  1. Mark PR as ready for review"
        echo "     gh pr ready $PR_NUMBER"
        ;;
      unstable)
        echo "  1. Check which CI checks failed:"
        echo "     gh pr checks $PR_NUMBER"
        echo ""
        echo "  2. View detailed logs:"
        echo "     gh pr checks $PR_NUMBER --web"
        echo ""
        echo "  3. Fix failing checks and push"
        ;;
      blocked)
        if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
          echo "  1. Fetch latest from base:"
          echo "     git fetch origin dev"
          echo ""
          echo "  2. Rebase and resolve conflicts:"
          echo "     git rebase origin/dev"
          echo ""
          echo "  3. Push resolved changes:"
          echo "     git push --force-with-lease"
        elif [[ "$REVIEW_DECISION" == "CHANGES_REQUESTED" ]]; then
          echo "  1. View review comments:"
          echo "     gh pr view $PR_NUMBER --comments"
          echo ""
          echo "  2. Address feedback and push"
          echo ""
          echo "  3. Request re-review:"
          echo "     gh pr review $PR_NUMBER --request-review"
        fi
        ;;
      behind)
        echo "  1. Update branch from base:"
        echo "     gh api repos/\$(gh repo view --json nameWithOwner -q .nameWithOwner)/pulls/$PR_NUMBER/update-branch -X PUT"
        echo ""
        echo "     OR manually:"
        echo "     git fetch origin dev && git merge origin/dev && git push"
        ;;
      unknown)
        echo "  GitHub is still calculating mergeability."
        echo "  Wait 30-60 seconds and re-run this check."
        ;;
      *)
        echo "  State: $LIFECYCLE_STATE"
        echo "  See docs/PR_MERGEABILITY_WORKFLOW.md for detailed resolution steps"
        ;;
    esac

    echo ""
    echo "After resolving, re-run:"
    echo "  ./scripts/verify-pr-mergeable.sh $PR_NUMBER"
    echo ""
    echo "See docs/PR_MERGEABILITY_WORKFLOW.md for complete workflow"
    echo ""
    exit 1
  fi
fi
