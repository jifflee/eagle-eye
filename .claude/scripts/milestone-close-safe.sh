#!/bin/bash
set -euo pipefail
# milestone-close-safe.sh
# Safely close a milestone with validation and optional auto-promotion to QA
#
# Usage:
#   ./scripts/milestone-close-safe.sh                     # Close active milestone
#   ./scripts/milestone-close-safe.sh "MVP"               # Close specific milestone
#   ./scripts/milestone-close-safe.sh --auto-promote      # Auto-promote to QA after close
#   ./scripts/milestone-close-safe.sh --dry-run           # Preview without action
#   ./scripts/milestone-close-safe.sh --no-release        # Skip release/promotion prompts
#
# Returns:
#   0 - Success (milestone closed, promotion optional)
#   1 - Validation failed (milestone not ready to close)
#   2 - Error (API failure, script error)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
  source "${SCRIPT_DIR}/lib/common.sh"
else
  # Fallback logging functions if common.sh doesn't exist
  log_info() { echo "[INFO] $*"; }
  log_success() { echo "[SUCCESS] $*"; }
  log_warn() { echo "[WARN] $*"; }
  log_error() { echo "[ERROR] $*" >&2; }
fi

MILESTONE_NAME=""
DRY_RUN=false
AUTO_PROMOTE=false
NO_RELEASE=false
SKIP_VALIDATION=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --auto-promote)
      AUTO_PROMOTE=true
      shift
      ;;
    --no-release)
      NO_RELEASE=true
      shift
      ;;
    --skip-validation)
      SKIP_VALIDATION=true
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

# Step 1: Gather milestone data with validation
log_info "Validating milestone readiness..."
if [ -n "$MILESTONE_NAME" ]; then
  MILESTONE_DATA=$("$SCRIPT_DIR/milestone-close-data.sh" --validate "$MILESTONE_NAME" 2>&1) || true
else
  MILESTONE_DATA=$("$SCRIPT_DIR/milestone-close-data.sh" --validate 2>&1) || true
fi

if [ -z "$MILESTONE_DATA" ] || ! echo "$MILESTONE_DATA" | jq -e '.' >/dev/null 2>&1; then
  log_error "Failed to gather milestone data"
  exit 2
fi

# Check for errors in response
if echo "$MILESTONE_DATA" | jq -e '.error' >/dev/null 2>&1; then
  ERROR_MSG=$(echo "$MILESTONE_DATA" | jq -r '.error')
  log_error "$ERROR_MSG"
  exit 2
fi

# Extract milestone info
MILESTONE_TITLE=$(echo "$MILESTONE_DATA" | jq -r '.milestone.title')
MILESTONE_NUMBER=$(echo "$MILESTONE_DATA" | jq -r '.milestone.number')
OPEN_ISSUES=$(echo "$MILESTONE_DATA" | jq -r '.issues.open')
CLOSED_ISSUES=$(echo "$MILESTONE_DATA" | jq -r '.issues.closed')
TOTAL_ISSUES=$(echo "$MILESTONE_DATA" | jq -r '.issues.total')
COMPLETION_PCT=$(echo "$MILESTONE_DATA" | jq -r '.issues.completion_percent')
ALL_COMPLETE=$(echo "$MILESTONE_DATA" | jq -r '.readiness.all_issues_complete')
CAN_CLOSE=$(echo "$MILESTONE_DATA" | jq -r '.readiness.can_close')

# Display milestone status
echo ""
echo "=========================================="
echo "  Milestone: $MILESTONE_TITLE"
echo "=========================================="
echo ""
echo "Issue Status:"
echo "  Total:     $TOTAL_ISSUES issues"
echo "  Completed: $CLOSED_ISSUES issues"
echo "  Open:      $OPEN_ISSUES issues"
echo "  Progress:  $COMPLETION_PCT%"
echo ""

# Step 2: Check for validation issue (validation gate)
if [ "$SKIP_VALIDATION" != true ]; then
  log_info "Checking for validation issue..."

  VALIDATION_TITLE="Pre-Close Validation: $MILESTONE_TITLE"
  VALIDATION_ISSUE=$(gh issue list \
    --label "milestone-validation" \
    --search "\"$VALIDATION_TITLE\" in:title" \
    --json number,title,state \
    --jq '.[] | select(.title == "'"$VALIDATION_TITLE"'")' 2>/dev/null || echo "")

  if [ -z "$VALIDATION_ISSUE" ] || [ "$VALIDATION_ISSUE" = "null" ]; then
    log_warn "No validation issue found for this milestone"
    echo ""
    echo "A validation issue is required before milestone closure."
    echo "This ensures all completed work was delivered, synced, and functional."
    echo ""
    echo "Creating validation issue now..."
    echo ""

    if [ "$DRY_RUN" = false ]; then
      # Auto-generate validation issue
      "$SCRIPT_DIR/generate-milestone-validation.sh" "$MILESTONE_TITLE"

      if [ $? -eq 0 ]; then
        log_warn "Validation issue created. Complete the checklist before closing milestone."
        echo ""
        echo "To close the milestone after validation:"
        echo "  1. Complete the validation checklist in the newly created issue"
        echo "  2. Close the validation issue"
        echo "  3. Re-run this command: /milestone-close"
        echo ""
        exit 1
      else
        log_error "Failed to create validation issue"
        echo ""
        echo "You can bypass validation with: /milestone-close --skip-validation"
        exit 2
      fi
    else
      log_info "[DRY RUN] Would create validation issue and block closure"
      exit 1
    fi
  else
    VALIDATION_NUMBER=$(echo "$VALIDATION_ISSUE" | jq -r '.number')
    VALIDATION_STATE=$(echo "$VALIDATION_ISSUE" | jq -r '.state')

    if [ "$VALIDATION_STATE" = "open" ]; then
      log_warn "Validation issue #$VALIDATION_NUMBER is still OPEN"
      echo ""
      echo "Milestone cannot be closed until validation is complete."
      echo ""
      echo "Validation issue: #$VALIDATION_NUMBER"
      echo "URL: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/issues/$VALIDATION_NUMBER"
      echo ""
      echo "Next steps:"
      echo "  1. Complete all validation checks in issue #$VALIDATION_NUMBER"
      echo "  2. Close the validation issue"
      echo "  3. Re-run this command: /milestone-close"
      echo ""
      echo "Or bypass validation: /milestone-close --skip-validation"
      echo ""

      if [ "$DRY_RUN" = false ]; then
        exit 1
      else
        log_info "[DRY RUN] Would block closure due to open validation issue"
      fi
    else
      log_success "Validation issue #$VALIDATION_NUMBER is CLOSED ✓"
      echo "  All deliverables have been validated"
      echo ""
    fi
  fi
else
  log_warn "Skipping validation gate (--skip-validation flag)"
  echo ""
fi

# Step 3: Check if milestone can be closed
if [ "$ALL_COMPLETE" != "true" ]; then
  log_warn "Milestone has $OPEN_ISSUES open issues remaining"

  # List open issues
  OPEN_ISSUE_DETAILS=$(echo "$MILESTONE_DATA" | jq -r '.issues.open_details')
  if [ "$OPEN_ISSUE_DETAILS" != "null" ] && [ -n "$OPEN_ISSUE_DETAILS" ]; then
    echo ""
    echo "Open issues:"
    echo "$OPEN_ISSUE_DETAILS" | jq -r '.[] | "  #\(.number) - \(.title)"'
  fi

  echo ""
  echo "Recommended actions:"
  echo "1. Run /milestone-complete-auto for intelligent triage (MVP-critical vs deferrable)"
  echo "2. Manually close or defer remaining issues"
  echo "3. Cancel milestone closure"
  echo ""

  if [ "$DRY_RUN" = false ]; then
    read -p "Continue with milestone closure anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Milestone closure cancelled"
      exit 0
    fi
  else
    log_info "[DRY RUN] Would prompt to continue despite open issues"
  fi
fi

# Step 4: Close the milestone
if [ "$DRY_RUN" = true ]; then
  log_info "[DRY RUN] Would close milestone #$MILESTONE_NUMBER ($MILESTONE_TITLE)"
else
  log_info "Closing milestone #$MILESTONE_NUMBER..."
  gh api "repos/:owner/:repo/milestones/$MILESTONE_NUMBER" \
    -X PATCH \
    -f state=closed \
    >/dev/null 2>&1

  if [ $? -eq 0 ]; then
    log_success "Milestone closed successfully"
  else
    log_error "Failed to close milestone"
    exit 2
  fi
fi

echo ""
echo "=========================================="
echo "  Milestone Closed: $MILESTONE_TITLE"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Issues completed: $CLOSED_ISSUES"
echo "  Completion rate:  $COMPLETION_PCT%"
echo ""

# Step 5: Handle promotion to QA
if [ "$NO_RELEASE" = true ]; then
  log_info "Skipping release workflow (--no-release flag)"
  exit 0
fi

# Check if we should promote to QA
PROMO_ARGS=""
if [ -n "$MILESTONE_TITLE" ]; then
  PROMO_ARGS="--milestone \"$MILESTONE_TITLE\""
fi

if [ "$AUTO_PROMOTE" = true ]; then
  log_info "Auto-promotion enabled, triggering dev→qa promotion..."

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would run: ./scripts/milestone-complete-promotion.sh $PROMO_ARGS --auto-merge"
    exit 0
  fi

  # Run promotion script
  if [ -n "$MILESTONE_TITLE" ]; then
    "$SCRIPT_DIR/milestone-complete-promotion.sh" --milestone "$MILESTONE_TITLE" --auto-merge
  else
    "$SCRIPT_DIR/milestone-complete-promotion.sh" --auto-merge
  fi

  PROMO_EXIT=$?

  if [ $PROMO_EXIT -eq 0 ]; then
    log_success "Auto-promotion to QA completed successfully"
  elif [ $PROMO_EXIT -eq 1 ]; then
    log_warn "Auto-promotion blocked (see details above)"
    log_info "Milestone closed, but QA promotion must be done manually"
  else
    log_error "Auto-promotion failed (see details above)"
    log_info "Milestone closed, but QA promotion must be done manually"
  fi
else
  # Prompt user for promotion
  echo "Next steps:"
  echo ""
  echo "The milestone has been closed. Would you like to promote dev→qa for QA validation?"
  echo ""

  if [ "$DRY_RUN" = false ]; then
    read -p "Promote dev → qa? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      log_info "Triggering dev→qa promotion..."

      if [ -n "$MILESTONE_TITLE" ]; then
        "$SCRIPT_DIR/milestone-complete-promotion.sh" --milestone "$MILESTONE_TITLE" --auto-merge
      else
        "$SCRIPT_DIR/milestone-complete-promotion.sh" --auto-merge
      fi

      if [ $? -eq 0 ]; then
        log_success "Promotion to QA initiated"
      else
        log_warn "Promotion encountered issues (see details above)"
      fi
    else
      log_info "Skipping QA promotion"
      echo ""
      echo "To promote manually later, run:"
      echo "  /release-promote-qa"
      echo "  OR"
      echo "  ./scripts/milestone-complete-promotion.sh --milestone \"$MILESTONE_TITLE\""
    fi
  else
    log_info "[DRY RUN] Would prompt to promote dev→qa"
  fi
fi

echo ""
log_success "Milestone closure workflow complete"
exit 0
