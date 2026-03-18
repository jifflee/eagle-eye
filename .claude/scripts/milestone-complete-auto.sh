#!/bin/bash
set -euo pipefail
# milestone-complete-auto.sh
# Orchestrate milestone completion with MVP analysis, issue triage, and auto-promotion
#
# Usage:
#   ./scripts/milestone-complete-auto.sh                     # Analyze active milestone
#   ./scripts/milestone-complete-auto.sh "sprint-1/13"       # Analyze specific milestone
#   ./scripts/milestone-complete-auto.sh --auto              # Auto-move deferrals without prompts
#   ./scripts/milestone-complete-auto.sh --dry-run           # Preview analysis without action
#   ./scripts/milestone-complete-auto.sh --close             # Close milestone after validation
#   ./scripts/milestone-complete-auto.sh --auto-promote      # Auto-promote to QA after close
#
# Returns:
#   0 - Success (analysis complete, actions taken as requested)
#   1 - Milestone not ready to close (blockers exist)
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
AUTO=false
CLOSE_MILESTONE=false
AUTO_PROMOTE=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --auto)
      AUTO=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --close)
      CLOSE_MILESTONE=true
      shift
      ;;
    --auto-promote)
      AUTO_PROMOTE=true
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

# Step 1: Gather milestone analysis data
log_info "Analyzing milestone..."
if [ -n "$MILESTONE_NAME" ]; then
  ANALYSIS_DATA=$("$SCRIPT_DIR/milestone-complete-analysis.sh" "$MILESTONE_NAME" 2>&1) || true
else
  ANALYSIS_DATA=$("$SCRIPT_DIR/milestone-complete-analysis.sh" 2>&1) || true
fi

if [ -z "$ANALYSIS_DATA" ] || ! echo "$ANALYSIS_DATA" | jq -e '.' >/dev/null 2>&1; then
  log_error "Failed to gather milestone analysis"
  exit 2
fi

# Check for errors in response
if echo "$ANALYSIS_DATA" | jq -e '.error' >/dev/null 2>&1; then
  ERROR_MSG=$(echo "$ANALYSIS_DATA" | jq -r '.error')
  log_error "$ERROR_MSG"
  exit 2
fi

# Extract analysis info
MILESTONE_TITLE=$(echo "$ANALYSIS_DATA" | jq -r '.milestone.title')
MILESTONE_NUMBER=$(echo "$ANALYSIS_DATA" | jq -r '.milestone.number')
TOTAL_OPEN=$(echo "$ANALYSIS_DATA" | jq -r '.total_open')
MVP_CRITICAL_COUNT=$(echo "$ANALYSIS_DATA" | jq -r '.analysis.mvp_critical | length')
DEFERRABLE_COUNT=$(echo "$ANALYSIS_DATA" | jq -r '.analysis.deferrable | length')
IN_PROGRESS_COUNT=$(echo "$ANALYSIS_DATA" | jq -r '.analysis.in_progress | length')
READY_TO_CLOSE=$(echo "$ANALYSIS_DATA" | jq -r '.recommendation.ready_to_close')
BLOCKERS=$(echo "$ANALYSIS_DATA" | jq -r '.recommendation.blockers | join(", ")')

# Display analysis
echo ""
echo "=========================================="
echo "  Milestone Analysis: $MILESTONE_TITLE"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Total Open:      $TOTAL_OPEN issues"
echo "  MVP-Critical:    $MVP_CRITICAL_COUNT issues"
echo "  Deferrable:      $DEFERRABLE_COUNT issues"
echo "  In-Progress:     $IN_PROGRESS_COUNT issues"
echo ""

# Display MVP-Critical issues
if [ "$MVP_CRITICAL_COUNT" -gt 0 ]; then
  echo "MVP-Critical Issues (must complete):"
  echo "$ANALYSIS_DATA" | jq -r '.analysis.mvp_critical[] | "  #\(.number) - \(.title) (\(.reason))"'
  echo ""
fi

# Display Deferrable issues
if [ "$DEFERRABLE_COUNT" -gt 0 ]; then
  echo "Deferrable Issues (can move to backlog):"
  echo "$ANALYSIS_DATA" | jq -r '.analysis.deferrable[] | "  #\(.number) - \(.title) (\(.reason))"'
  echo ""
fi

# Display In-Progress issues
if [ "$IN_PROGRESS_COUNT" -gt 0 ]; then
  echo "In-Progress Issues (active work):"
  echo "$ANALYSIS_DATA" | jq -r '.analysis.in_progress[] | "  #\(.number) - \(.title) (worktree: \(.worktree // "none"))"'
  echo ""
fi

# Step 2: Handle deferrals
if [ "$DEFERRABLE_COUNT" -gt 0 ]; then
  if [ "$AUTO" = true ]; then
    log_info "Auto-moving $DEFERRABLE_COUNT deferrable issues to backlog..."

    if [ "$DRY_RUN" = false ]; then
      # Get or create backlog milestone
      BACKLOG_MILESTONE="backlog"
      BACKLOG_NUMBER=$(gh api repos/:owner/:repo/milestones --jq ".[] | select(.title==\"$BACKLOG_MILESTONE\") | .number" 2>/dev/null || echo "")

      if [ -z "$BACKLOG_NUMBER" ]; then
        log_info "Creating backlog milestone..."
        BACKLOG_NUMBER=$(gh api repos/:owner/:repo/milestones -f title="$BACKLOG_MILESTONE" -f state=open --jq '.number')
      fi

      # Move deferrable issues
      echo "$ANALYSIS_DATA" | jq -r '.analysis.deferrable[].number' | while read -r issue_num; do
        log_info "Moving issue #$issue_num to backlog..."
        gh issue edit "$issue_num" --milestone "$BACKLOG_MILESTONE" 2>/dev/null || true
      done

      log_success "Moved $DEFERRABLE_COUNT issues to backlog"
    else
      log_info "[DRY RUN] Would move $DEFERRABLE_COUNT issues to backlog"
    fi
  else
    echo "Action required:"
    echo "Move $DEFERRABLE_COUNT deferrable issues to backlog? [y/n/select]"
    echo ""
    echo "  y      - Move all to backlog"
    echo "  n      - Keep in current milestone"
    echo "  select - Choose which issues to move"
    echo ""

    if [ "$DRY_RUN" = false ]; then
      read -p "Choice: " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Same logic as AUTO mode
        BACKLOG_MILESTONE="backlog"
        BACKLOG_NUMBER=$(gh api repos/:owner/:repo/milestones --jq ".[] | select(.title==\"$BACKLOG_MILESTONE\") | .number" 2>/dev/null || echo "")

        if [ -z "$BACKLOG_NUMBER" ]; then
          log_info "Creating backlog milestone..."
          BACKLOG_NUMBER=$(gh api repos/:owner/:repo/milestones -f title="$BACKLOG_MILESTONE" -f state=open --jq '.number')
        fi

        echo "$ANALYSIS_DATA" | jq -r '.analysis.deferrable[].number' | while read -r issue_num; do
          log_info "Moving issue #$issue_num to backlog..."
          gh issue edit "$issue_num" --milestone "$BACKLOG_MILESTONE" 2>/dev/null || true
        done

        log_success "Moved $DEFERRABLE_COUNT issues to backlog"
      fi
    else
      log_info "[DRY RUN] Would prompt to move deferrables"
    fi
  fi
fi

# Step 3: Check closure readiness
echo ""
echo "Closure Readiness:"
if [ "$READY_TO_CLOSE" = "true" ]; then
  log_success "Milestone is ready to close"

  # Generate validation issue if ready to close
  log_info "Generating validation issue..."

  if [ "$DRY_RUN" = false ]; then
    "$SCRIPT_DIR/generate-milestone-validation.sh" "$MILESTONE_TITLE" || true

    if [ $? -eq 0 ]; then
      log_info "Validation issue created (or already exists)"
      echo ""
      echo "Next step: Complete the validation checklist before closing milestone"
      echo ""
    else
      log_warn "Could not create validation issue (may already exist)"
    fi
  else
    log_info "[DRY RUN] Would generate validation issue"
  fi
else
  log_warn "Milestone is NOT ready to close"
  if [ -n "$BLOCKERS" ]; then
    echo "  Blockers: $BLOCKERS"
  fi
  echo ""
  echo "Recommended actions:"
  echo "1. Complete in-progress work (use /sprint-status-pm to check progress)"
  echo "2. Move remaining issues to backlog or next milestone"
  echo "3. Re-run this analysis when ready"
  echo ""

  if [ "$CLOSE_MILESTONE" = true ]; then
    log_error "Cannot close milestone due to blockers"
    exit 1
  else
    log_info "Milestone analysis complete (not ready to close)"
    exit 0
  fi
fi

# Step 4: Close milestone if requested
if [ "$CLOSE_MILESTONE" = true ]; then
  log_info "Closing milestone #$MILESTONE_NUMBER..."

  if [ "$DRY_RUN" = false ]; then
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
  else
    log_info "[DRY RUN] Would close milestone #$MILESTONE_NUMBER"
  fi

  echo ""
  echo "=========================================="
  echo "  Milestone Closed: $MILESTONE_TITLE"
  echo "=========================================="
  echo ""
fi

# Step 5: Handle auto-promotion if requested
if [ "$CLOSE_MILESTONE" = true ] && [ "$AUTO_PROMOTE" = true ]; then
  log_info "Auto-promotion enabled, triggering dev→qa promotion..."

  if [ "$DRY_RUN" = false ]; then
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
    log_info "[DRY RUN] Would run auto-promotion to QA"
  fi
elif [ "$CLOSE_MILESTONE" = true ] && [ "$AUTO_PROMOTE" = false ]; then
  echo ""
  echo "Next steps:"
  echo "  To promote dev→qa for QA validation, run:"
  echo "    /release-promote-qa"
  echo "    OR"
  echo "    ./scripts/milestone-complete-promotion.sh --milestone \"$MILESTONE_TITLE\""
  echo ""
fi

log_success "Milestone completion workflow finished"
exit 0
