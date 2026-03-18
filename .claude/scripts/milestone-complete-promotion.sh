#!/bin/bash
set -euo pipefail
# milestone-complete-promotion.sh
# Automatically promotes dev→qa when a milestone is complete
#
# Usage:
#   ./scripts/milestone-complete-promotion.sh                     # Use active milestone
#   ./scripts/milestone-complete-promotion.sh "MVP"               # Specific milestone
#   ./scripts/milestone-complete-promotion.sh --milestone "MVP"   # Alternative syntax
#   ./scripts/milestone-complete-promotion.sh --dry-run           # Preview without action
#   ./scripts/milestone-complete-promotion.sh --auto-merge        # Merge PR automatically
#
# Triggers:
#   - Manual invocation via CLI
#   - GitHub Actions on milestone closure
#   - /milestone-close skill integration
#
# Returns:
#   0 - Success (PR created and/or merged)
#   1 - Promotion blocked (not ready)
#   2 - Error (API failure, etc.)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

MILESTONE_NAME=""
DRY_RUN=false
AUTO_MERGE=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --milestone)
      MILESTONE_NAME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --auto-merge)
      AUTO_MERGE=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      MILESTONE_NAME="$1"
      shift
      ;;
  esac
done

# Gather promotion readiness data
log_info "Checking promotion readiness..."
if [ -n "$MILESTONE_NAME" ]; then
  PROMO_DATA=$("$SCRIPT_DIR/auto-promote-to-qa-data.sh" --milestone "$MILESTONE_NAME" --changelog)
else
  PROMO_DATA=$("$SCRIPT_DIR/auto-promote-to-qa-data.sh" --changelog)
fi

if [ $? -ne 0 ] || [ -z "$PROMO_DATA" ]; then
  log_error "Failed to gather promotion data"
  exit 2
fi

# Check for errors in response
if echo "$PROMO_DATA" | jq -e '.error' >/dev/null 2>&1; then
  ERROR_MSG=$(echo "$PROMO_DATA" | jq -r '.error')
  log_error "$ERROR_MSG"
  exit 2
fi

# Extract key fields
MILESTONE_TITLE=$(echo "$PROMO_DATA" | jq -r '.milestone.title')
MILESTONE_NUMBER=$(echo "$PROMO_DATA" | jq -r '.milestone.number')
ALL_COMPLETE=$(echo "$PROMO_DATA" | jq -r '.milestone.issues.all_complete')
COMPLETION_PCT=$(echo "$PROMO_DATA" | jq -r '.milestone.issues.completion_percent')
OPEN_ISSUES=$(echo "$PROMO_DATA" | jq -r '.milestone.issues.open')
CLOSED_ISSUES=$(echo "$PROMO_DATA" | jq -r '.milestone.issues.closed')
CAN_PROMOTE=$(echo "$PROMO_DATA" | jq -r '.readiness.can_auto_promote')
BLOCK_REASONS=$(echo "$PROMO_DATA" | jq -r '.readiness.block_reasons | join(", ")')
COMMITS_AHEAD=$(echo "$PROMO_DATA" | jq -r '.branch_state.commits_ahead')
QA_EXISTS=$(echo "$PROMO_DATA" | jq -r '.branch_state.qa_branch_exists')
CI_STATUS=$(echo "$PROMO_DATA" | jq -r '.ci_status')
EXISTING_PR=$(echo "$PROMO_DATA" | jq -r '.existing_pr')

# Output status
echo ""
echo "=========================================="
echo "  Milestone: $MILESTONE_TITLE"
echo "=========================================="
echo ""
echo "Issue Status:"
echo "  Completed: $CLOSED_ISSUES issues"
echo "  Open:      $OPEN_ISSUES issues"
echo "  Progress:  $COMPLETION_PCT%"
echo ""
echo "Branch Status:"
echo "  dev ahead of qa: $COMMITS_AHEAD commits"
echo "  qa branch exists: $QA_EXISTS"
echo "  CI on dev:        $CI_STATUS"
echo ""

# Check if promotion is possible
if [ "$CAN_PROMOTE" != "true" ]; then
  log_warn "Promotion blocked: $BLOCK_REASONS"

  # Provide actionable guidance
  if [ "$ALL_COMPLETE" != "true" ]; then
    echo ""
    echo "Milestone still has $OPEN_ISSUES open issues."
    echo "Close all issues before promotion, or use /milestone-close to handle them."
  fi

  if echo "$BLOCK_REASONS" | grep -q "CI not passing"; then
    echo ""
    echo "CI is failing on dev branch."
    echo "Fix CI issues before promotion."
  fi

  if echo "$BLOCK_REASONS" | grep -q "open PRs to dev"; then
    echo ""
    echo "There are open PRs targeting dev."
    echo "Merge or close them before promotion."
  fi

  exit 1
fi

# Check for existing PR
if [ "$EXISTING_PR" != "null" ]; then
  EXISTING_PR_NUMBER=$(echo "$EXISTING_PR" | jq -r '.number')
  EXISTING_PR_URL=$(echo "$EXISTING_PR" | jq -r '.url')
  log_info "Existing PR found: #$EXISTING_PR_NUMBER"

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would merge existing PR #$EXISTING_PR_NUMBER"
    exit 0
  fi

  if [ "$AUTO_MERGE" = true ]; then
    log_info "Auto-merging existing PR #$EXISTING_PR_NUMBER..."
    if gh pr merge "$EXISTING_PR_NUMBER" --squash --delete-branch; then
      log_success "PR #$EXISTING_PR_NUMBER merged successfully"
      echo ""
      echo "Promotion complete!"
      echo "dev branch has been merged to qa."
      exit 0
    else
      log_error "Failed to merge PR #$EXISTING_PR_NUMBER"
      exit 2
    fi
  else
    log_info "PR already exists. Merge manually or use --auto-merge"
    echo "PR URL: $EXISTING_PR_URL"
    exit 0
  fi
fi

# Build PR body with changelog
FEATURES=$(echo "$PROMO_DATA" | jq -r '.changelog.features | if length > 0 then map("- " + .) | join("\n") else "None" end')
FIXES=$(echo "$PROMO_DATA" | jq -r '.changelog.fixes | if length > 0 then map("- " + .) | join("\n") else "None" end')
OTHER=$(echo "$PROMO_DATA" | jq -r '.changelog.other | if length > 0 then map("- " + .) | join("\n") else "None" end')

PR_BODY=$(cat <<EOF
## Milestone Complete: $MILESTONE_TITLE

Automatically promoting \`dev\` to \`qa\` after milestone completion.

### Summary
- **Issues Completed:** $CLOSED_ISSUES
- **Commits:** $COMMITS_AHEAD

### Features
$FEATURES

### Fixes
$FIXES

### Other Changes
$OTHER

---
*Automatically created by milestone-complete-promotion.sh*
EOF
)

PR_TITLE="qa: Promote dev for $MILESTONE_TITLE validation"

# Dry run check
if [ "$DRY_RUN" = true ]; then
  log_info "[DRY RUN] Would create PR:"
  echo "  Title: $PR_TITLE"
  echo "  Base: qa"
  echo "  Head: dev"
  echo ""
  echo "PR Body:"
  echo "$PR_BODY"
  exit 0
fi

# Create the qa branch if it doesn't exist
if [ "$QA_EXISTS" != "true" ]; then
  log_info "Creating qa branch from dev..."
  git fetch origin dev
  git push origin origin/dev:refs/heads/qa
  log_success "qa branch created"
fi

# Create PR
log_info "Creating PR from dev to qa..."
PR_URL=$(gh pr create \
  --base qa \
  --head dev \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  2>&1)

if [ $? -ne 0 ]; then
  log_error "Failed to create PR: $PR_URL"
  exit 2
fi

log_success "PR created: $PR_URL"

# Auto-merge if requested
if [ "$AUTO_MERGE" = true ]; then
  log_info "Waiting for CI checks..."
  sleep 5  # Give CI a moment to start

  PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')

  log_info "Auto-merging PR #$PR_NUMBER..."
  if gh pr merge "$PR_NUMBER" --squash --delete-branch --auto; then
    log_success "Auto-merge enabled for PR #$PR_NUMBER"
    echo ""
    echo "PR will be merged when all checks pass."
  else
    log_warn "Could not enable auto-merge. Manual merge may be required."
  fi
fi

echo ""
echo "=========================================="
echo "  Promotion initiated!"
echo "=========================================="
echo ""
echo "PR: $PR_URL"
echo ""
if [ "$AUTO_MERGE" != true ]; then
  echo "Next steps:"
  echo "1. Review the PR"
  echo "2. Merge when ready: gh pr merge <number> --squash"
fi

exit 0
