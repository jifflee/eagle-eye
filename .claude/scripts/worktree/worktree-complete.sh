#!/bin/bash
set -euo pipefail
# worktree-complete.sh
# Orchestrates the complete worktree completion flow: PR merge, issue close, cleanup
# size-ok: multi-step orchestration with CI wait, merge, verification, and cleanup
#
# Usage:
#   ./scripts/worktree-complete.sh [OPTIONS]
#
# Options:
#   --issue <N>      Issue number (auto-detected from branch if not provided)
#   --wait           Wait for CI to complete before merging
#   --timeout <sec>  Timeout in seconds when waiting (default: 600)
#   --auto           Non-interactive mode
#   --skip-cleanup   Don't show cleanup instructions
#   --dry-run        Show what would be done without executing
#   --json           Output JSON result
#
# This script:
#   1. Verifies all commits are pushed
#   2. Finds or creates PR
#   3. Auto-merges when conditions met
#   4. Verifies issue closure
#   5. Provides cleanup instructions

set -e

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ DEPRECATION NOTICE (Phase 2 - Apr 2026)                                     │
# │                                                                             │
# │ This script is DEPRECATED and scheduled for removal in Phase 3 (H2 2026).  │
# │                                                                             │
# │ Replacements:                                                               │
# │   - Container mode: /sprint-work --issue N --container                     │
# │   - PR iteration:   /pr-iterate --auto                                     │
# │   - PR status:      /pr-status                                             │
# │                                                                             │
# │ See: docs/CONTAINERIZED_WORKFLOW.md#worktree-deprecation-timeline          │
# └─────────────────────────────────────────────────────────────────────────────┘
echo "⚠️  DEPRECATED: worktree-complete.sh → Use '/sprint-work --container' or '/pr-iterate'" >&2

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Defaults
ISSUE=""
WAIT_FOR_CI=false
TIMEOUT=600
AUTO_MODE=false
SKIP_CLEANUP=false
DRY_RUN=false
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --issue)
      ISSUE="$2"
      shift 2
      ;;
    --wait)
      WAIT_FOR_CI=true
      shift
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --auto)
      AUTO_MODE=true
      shift
      ;;
    --skip-cleanup)
      SKIP_CLEANUP=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Orchestrates the complete worktree completion flow."
      echo ""
      echo "Options:"
      echo "  --issue <N>      Issue number (auto-detected if not provided)"
      echo "  --wait           Wait for CI to complete before merging"
      echo "  --timeout <sec>  Timeout in seconds when waiting (default: 600)"
      echo "  --auto           Non-interactive mode"
      echo "  --skip-cleanup   Don't show cleanup instructions"
      echo "  --dry-run        Show what would be done"
      echo "  --json           Output JSON result"
      exit 0
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Output helpers
log() {
  if ! $JSON_OUTPUT; then
    echo -e "$1"
  fi
}

log_step() {
  if ! $JSON_OUTPUT; then
    echo ""
    echo -e "${BLUE:-}Step $1: $2${NC:-}"
  fi
}

log_warning() {
  log_warn "$@"
}

# Get current branch
BRANCH=$(git branch --show-current 2>/dev/null)
if [ -z "$BRANCH" ]; then
  log_error "Not in a git repository"
  exit 1
fi

# Auto-detect issue from branch name if not provided
if [ -z "$ISSUE" ]; then
  ISSUE=$(echo "$BRANCH" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+' || echo "")
  if [ -z "$ISSUE" ]; then
    log_error "Could not detect issue number from branch '$BRANCH'"
    log "Please provide --issue <N>"
    exit 1
  fi
fi

log ""
log "=== Worktree Completion Flow ==="
log "Issue: #$ISSUE"
log "Branch: $BRANCH"

# Step 1: Verify work status
log_step "1" "Verifying work status..."

# Check for uncommitted changes
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  log_error "Working tree has uncommitted changes"
  log "Please commit or stash changes first"
  exit 1
fi

# Check for unpushed commits
UNPUSHED=$(git log --oneline @{upstream}..HEAD 2>/dev/null | wc -l | tr -d ' ')
if [ "$UNPUSHED" -gt 0 ]; then
  log_warning "Found $UNPUSHED unpushed commit(s)"
  if $DRY_RUN; then
    log "(dry-run) Would push $UNPUSHED commit(s)"
  else
    # Auto-push in worktree mode - no prompt needed
    log "Pushing commits..."
    if ! git push 2>&1; then
      log_error "Failed to push commits"
      log "Please push manually and re-run this script"
      exit 1
    fi
  fi
fi

log_success "Work status verified"

# Step 2: Check PR status
log_step "2" "Checking PR status..."

# Find PR for this branch (include merge state for accurate status reporting)
PR_INFO=$(gh pr list --head "$BRANCH" --json number,title,state,mergeable,mergeStateStatus,reviewDecision,isDraft --jq '.[0] // empty' 2>/dev/null)
PR_STATE=""

if [ -z "$PR_INFO" ]; then
  # No PR exists - create one
  log_warning "No PR found for branch $BRANCH"

  if $DRY_RUN; then
    log "(dry-run) Would create PR for issue #$ISSUE"
    PR_NUMBER="DRY_RUN"
  else
    # Auto-create PR in worktree mode - no prompt needed
    log "Creating PR..."
    if ! PR_URL=$(gh pr create --base dev --title "feat: Fixes #$ISSUE" --body "Fixes #$ISSUE" 2>&1); then
      log_error "Failed to create PR"
      log "Error: $PR_URL"
      exit 1
    fi
    PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')
    log_success "Created PR #$PR_NUMBER"
  fi
else
  PR_NUMBER=$(echo "$PR_INFO" | jq -r '.number')
  PR_STATE=$(echo "$PR_INFO" | jq -r '.state')
  PR_TITLE=$(echo "$PR_INFO" | jq -r '.title')
  MERGE_STATE=$(echo "$PR_INFO" | jq -r '.mergeStateStatus // "UNKNOWN"')
  REVIEW_DECISION=$(echo "$PR_INFO" | jq -r '.reviewDecision // ""')
  IS_DRAFT=$(echo "$PR_INFO" | jq -r '.isDraft // false')

  # Determine lifecycle state (consistent with sprint-status-data.sh)
  if [ "$IS_DRAFT" == "true" ]; then
    LIFECYCLE_STATE="draft"
    ACTION_NEEDED="Complete draft and mark ready for review"
  elif [ "$MERGE_STATE" == "CLEAN" ] && [ "$REVIEW_DECISION" == "APPROVED" ]; then
    LIFECYCLE_STATE="ready"
    ACTION_NEEDED="Ready to merge"
  elif [ "$MERGE_STATE" == "CLEAN" ]; then
    LIFECYCLE_STATE="open"
    ACTION_NEEDED="Awaiting review"
  elif [ "$MERGE_STATE" == "BLOCKED" ] || [ "$REVIEW_DECISION" == "CHANGES_REQUESTED" ]; then
    LIFECYCLE_STATE="blocked"
    ACTION_NEEDED="Resolve blocking issues"
  elif [ "$MERGE_STATE" == "UNSTABLE" ]; then
    LIFECYCLE_STATE="unstable"
    ACTION_NEEDED="Fix failing CI checks"
  elif [ "$MERGE_STATE" == "BEHIND" ]; then
    LIFECYCLE_STATE="behind"
    ACTION_NEEDED="Update branch with base"
  else
    LIFECYCLE_STATE="open"
    ACTION_NEEDED="Development in progress"
  fi

  log "Found PR #$PR_NUMBER: $PR_TITLE"
  log "  State: $PR_STATE | CI: $MERGE_STATE | Lifecycle: $LIFECYCLE_STATE"
  log "  Action: $ACTION_NEEDED"

  if [ "$PR_STATE" == "MERGED" ]; then
    log_success "PR already merged"
  elif [ "$PR_STATE" != "OPEN" ]; then
    log_error "PR is in unexpected state: $PR_STATE"
    exit 1
  fi
fi

# Step 3: Attempt auto-merge (if PR is open)
if [ "$PR_STATE" != "MERGED" ]; then
  log_step "3" "Attempting auto-merge..."

  MERGE_ARGS=""
  if $DRY_RUN; then
    MERGE_ARGS="$MERGE_ARGS --dry-run"
  fi

  if $WAIT_FOR_CI; then
    MERGE_ARGS="$MERGE_ARGS --wait --timeout $TIMEOUT"
  fi

  MERGE_ARGS="$MERGE_ARGS --json"

  # Run auto-merge
  set +e
  MERGE_RESULT=$("$SCRIPT_DIR/worktree-auto-merge.sh" "$PR_NUMBER" $MERGE_ARGS 2>&1)
  MERGE_EXIT=$?
  set -e

  if [ "$MERGE_EXIT" != "0" ]; then
    # Parse error from result
    ERROR_ACTION=$(echo "$MERGE_RESULT" | jq -r '.action // "unknown"' 2>/dev/null || echo "unknown")
    ERROR_REASON=$(echo "$MERGE_RESULT" | jq -r '.reason // "Unknown error"' 2>/dev/null || echo "$MERGE_RESULT")

    case "$ERROR_ACTION" in
      blocked)
        log_warning "Merge blocked: $ERROR_REASON"
        if ! $AUTO_MODE && ! $DRY_RUN; then
          log ""
          log "Options:"
          log "  1. Fix the issue and re-run this script"
          log "  2. Merge manually via GitHub UI"
        fi
        exit 2
        ;;
      waiting)
        log_warning "CI still running: $ERROR_REASON"
        log "Re-run with --wait to wait for CI"
        exit 2
        ;;
      timeout)
        log_error "Timeout: $ERROR_REASON"
        exit 3
        ;;
      *)
        log_error "Merge failed: $ERROR_REASON"
        exit 1
        ;;
    esac
  fi

  if $DRY_RUN; then
    log "(dry-run) Would merge PR #$PR_NUMBER"
  else
    log_success "PR merged successfully"
  fi
fi

# Step 4: Close linked issue
log_step "4" "Closing linked issue..."

ISSUE_STATE="UNKNOWN"
if $DRY_RUN; then
  log "(dry-run) Would close issue #$ISSUE"
else
  ISSUE_STATE=$(gh issue view "$ISSUE" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

  if [ "$ISSUE_STATE" == "CLOSED" ]; then
    log_success "Issue #$ISSUE is already closed"
  elif [ "$ISSUE_STATE" == "OPEN" ]; then
    log "Closing issue #$ISSUE..."
    if gh issue close "$ISSUE" --comment "Closed: PR #$PR_NUMBER merged to dev. Work is complete." 2>&1; then
      log_success "Closed issue #$ISSUE"
      ISSUE_STATE="CLOSED"
    else
      log_warning "Failed to close issue #$ISSUE — close manually: gh issue close $ISSUE"
    fi
  else
    log_warning "Issue #$ISSUE in unexpected state: $ISSUE_STATE"
  fi
fi

# Step 5: Cleanup instructions
IS_WORKTREE=false
if ! $SKIP_CLEANUP; then
  log_step "5" "Cleanup instructions..."

  # Detect if in worktree
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ ! -d "$TOPLEVEL/.git" ]; then
    IS_WORKTREE=true
  fi

  if $IS_WORKTREE; then
    MAIN_REPO=$(dirname "$TOPLEVEL")

    log ""
    log "To complete cleanup, run from the main repo:"
    log "  ${CYAN}cd $MAIN_REPO${NC}"
    log "  ${CYAN}./scripts/worktree-cleanup.sh $ISSUE --delete-branch${NC}"

    if $AUTO_MODE; then
      log ""
      log "Or for automated cleanup:"
      log "  ${CYAN}./scripts/worktree-cleanup.sh $ISSUE --delete-branch --auto${NC}"
    fi
  else
    log_success "Running in main repo - no worktree cleanup needed"
  fi
fi

log ""
log "=== Worktree Completion Flow Done ==="

# JSON output
if $JSON_OUTPUT; then
  MERGED_VALUE="false"
  if [ "$PR_STATE" == "MERGED" ] || { ! $DRY_RUN && [ "$MERGE_EXIT" == "0" ]; }; then
    MERGED_VALUE="true"
  fi
  CLOSED_VALUE="false"
  if [ "$ISSUE_STATE" == "CLOSED" ]; then
    CLOSED_VALUE="true"
  fi

  cat << EOF
{
  "success": true,
  "issue": $ISSUE,
  "pr_number": "$PR_NUMBER",
  "branch": "$BRANCH",
  "merged": $MERGED_VALUE,
  "issue_closed": $CLOSED_VALUE,
  "cleanup_needed": $IS_WORKTREE
}
EOF
fi
