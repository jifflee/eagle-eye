#!/bin/bash
set -euo pipefail
# worktree-cleanup.sh
# Safely removes a git worktree and optionally its branch
# size-ok: multi-mode worktree manager with cleanup, list, prune, and branch deletion
#
# Usage:
#   ./scripts/worktree-cleanup.sh <issue-number>
#   ./scripts/worktree-cleanup.sh <issue-number> --delete-branch
#   ./scripts/worktree-cleanup.sh --list
#   ./scripts/worktree-cleanup.sh --prune
#
# Must be run from the main repository (not a worktree)
#
# Enhanced Features (Issue #68):
#   - Detects pre-PR vs post-PR commits using classify-worktree-commits.sh
#   - Shows detailed commit status with classifications
#   - Offers cherry-pick option for post-merge commits
#
# Audit Logging:
#   Location: ~/.claude-tastic/logs/worktree-cleanup.log
#   Format: timestamp|user|repo|action|details|outcome
#   Example: 2026-01-12T14:30:00Z|jeff|my-repo|CLEANUP_START|issue=52|initiated
#
#   Actions logged:
#     CLEANUP_START   - Cleanup initiated
#     CLEANUP_ABORT   - User declined to proceed
#     CLEANUP_WARNING - User confirmed despite warnings
#     WORKTREE_REMOVED - Worktree successfully removed
#     BRANCH_DELETED  - Branch deleted
#     BRANCH_KEPT     - User declined branch deletion
#     CLEANUP_COMPLETE - Operation completed successfully
#     CHERRY_PICK     - Post-merge commits cherry-picked to new branch

set -e

# Script directory for calling sibling scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/framework-config.sh"

# DEPRECATION NOTICE: Worktree scripts are being phased out in favor of container-based
# execution. See docs/CONTAINERIZED_WORKFLOW.md#worktree-deprecation-timeline for timeline.
# Use: /sprint-work --issue N --container
echo "DEPRECATION: worktree-cleanup.sh will be removed in Phase 3. Use container mode instead." >&2

# Audit log configuration
LOG_DIR="${FRAMEWORK_LOG_DIR}"
LOG_FILE="${LOG_DIR}/worktree-cleanup.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Logging function for audit trail (non-blocking on failure)
log_action() {
  local action="$1"
  local details="$2"
  local outcome="$3"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local user=$(whoami)
  local repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

  if ! echo "${timestamp}|${user}|${repo_name}|${action}|${details}|${outcome}" >> "$LOG_FILE" 2>/dev/null; then
    echo -e "${YELLOW}Warning: Failed to write audit log to $LOG_FILE${NC}" >&2
  fi
}

# Check if in main repo
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ ! -d "$TOPLEVEL/.git" ]; then
  echo -e "${RED}Error: Must run from main repository, not a worktree${NC}"
  echo "Current directory appears to be a worktree."
  echo "Please cd to the main repository first."
  exit 1
fi

REPO_NAME=$(basename "$TOPLEVEL")
PARENT_DIR=$(dirname "$TOPLEVEL")

# Handle flags
case "$1" in
  --list)
    echo "Current worktrees:"
    echo ""
    git worktree list
    exit 0
    ;;
  --prune)
    echo "Pruning stale worktree references..."
    git worktree prune -v
    echo -e "${GREEN}Done${NC}"
    exit 0
    ;;
  --help|-h)
    echo "Usage: $0 <issue-number> [--delete-branch] [--auto] [--json]"
    echo "       $0 --list"
    echo "       $0 --prune"
    echo ""
    echo "Options:"
    echo "  <issue-number>    Issue number to clean up (e.g., 8)"
    echo "  --delete-branch   Also delete the local branch after removing worktree"
    echo "  --auto            Non-interactive mode for automation"
    echo "  --json            Output JSON result (requires --auto)"
    echo "  --list            List all current worktrees"
    echo "  --prune           Remove stale worktree references"
    echo ""
    echo "Auto Mode Behavior:"
    echo "  - Fails if uncommitted changes exist"
    echo "  - Auto-discards merged PR commits"
    echo "  - Auto-discards post-merge commits (with warning log)"
    echo "  - Force deletes branch if --delete-branch specified"
    echo ""
    echo "Enhanced Features:"
    echo "  - Classifies unpushed commits as MERGED, POST-MERGE, or UNMERGED"
    echo "  - Offers cherry-pick option for post-merge commits"
    echo "  - Safe discard recommendation for merged PR commits"
    echo ""
    echo "Related scripts:"
    echo "  classify-worktree-commits.sh  - Classify commits (JSON output)"
    echo "  worktree-cherry-pick.sh       - Cherry-pick post-merge commits"
    exit 0
    ;;
esac

# Parse arguments
ISSUE=""
DELETE_BRANCH=false
AUTO_MODE=false
JSON_OUTPUT=false

for arg in "$@"; do
  case "$arg" in
    --delete-branch)
      DELETE_BRANCH=true
      ;;
    --auto)
      AUTO_MODE=true
      ;;
    --json)
      JSON_OUTPUT=true
      ;;
    *)
      if [[ -z "$ISSUE" && "$arg" =~ ^[0-9]+$ ]]; then
        ISSUE="$arg"
      fi
      ;;
  esac
done

if [ -z "$ISSUE" ]; then
  echo -e "${RED}Error: Issue number required${NC}"
  echo "Usage: $0 <issue-number> [--delete-branch] [--auto] [--json]"
  exit 1
fi

# JSON output requires auto mode
if $JSON_OUTPUT && ! $AUTO_MODE; then
  echo -e "${RED}Error: --json requires --auto${NC}"
  exit 1
fi

# JSON output helper
output_json() {
  local success="$1"
  local action="$2"
  local message="$3"
  if $JSON_OUTPUT; then
    echo "{\"success\": $success, \"issue\": $ISSUE, \"action\": \"$action\", \"message\": \"$message\"}"
  fi
}

# Calculate worktree path
WORKTREE_PATH="$PARENT_DIR/${REPO_NAME}-issue-$ISSUE"

# Check if worktree exists
if [ ! -d "$WORKTREE_PATH" ]; then
  echo -e "${YELLOW}Warning: Worktree not found at $WORKTREE_PATH${NC}"
  echo ""
  echo "Existing worktrees:"
  git worktree list
  exit 1
fi

# Get branch name from worktree
BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current 2>/dev/null || echo "")

echo "Removing worktree for issue #$ISSUE..."
echo "  Path: $WORKTREE_PATH"
echo "  Branch: $BRANCH"
echo ""

log_action "CLEANUP_START" "issue=$ISSUE path=$WORKTREE_PATH branch=$BRANCH" "initiated"

# Check for uncommitted changes
if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null)" ]; then
  echo -e "${RED}Warning: Worktree has uncommitted changes!${NC}"
  echo ""
  git -C "$WORKTREE_PATH" status --short
  echo ""

  if $AUTO_MODE; then
    log_action "CLEANUP_ABORT" "issue=$ISSUE path=$WORKTREE_PATH" "uncommitted_changes_auto_mode"
    echo -e "${RED}Auto mode: Cannot continue with uncommitted changes${NC}"
    output_json "false" "uncommitted_changes" "Worktree has uncommitted changes"
    exit 1
  fi

  read -p "Continue anyway? (y/N) " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    log_action "CLEANUP_ABORT" "issue=$ISSUE path=$WORKTREE_PATH" "uncommitted_changes_user_declined"
    echo "Aborted."
    exit 1
  fi
  log_action "CLEANUP_WARNING" "issue=$ISSUE path=$WORKTREE_PATH" "uncommitted_changes_user_confirmed"
fi

# Check for unpushed commits with enhanced classification
UNPUSHED=$(git -C "$WORKTREE_PATH" log --oneline @{upstream}..HEAD 2>/dev/null || echo "")
if [ -n "$UNPUSHED" ]; then
  UNPUSHED_COUNT=$(echo "$UNPUSHED" | wc -l | tr -d ' ')
  echo -e "${YELLOW}Warning: Worktree has $UNPUSHED_COUNT unpushed commit(s)${NC}"
  echo ""

  # Try to classify commits using the classification script
  CLASSIFICATION=""
  if [ -x "$SCRIPT_DIR/classify-worktree-commits.sh" ]; then
    CLASSIFICATION=$("$SCRIPT_DIR/classify-worktree-commits.sh" "$ISSUE" 2>/dev/null || echo "")
  fi

  if [ -n "$CLASSIFICATION" ] && [ "$(echo "$CLASSIFICATION" | jq -r '.success // false')" = "true" ]; then
    # Show enhanced commit details
    PR_MERGED=$(echo "$CLASSIFICATION" | jq -r '.pr_merged // false')
    PR_NUMBER=$(echo "$CLASSIFICATION" | jq -r '.pr_number // ""')
    MERGED_COUNT=$(echo "$CLASSIFICATION" | jq -r '.summary.merged // 0')
    POST_MERGE_COUNT=$(echo "$CLASSIFICATION" | jq -r '.summary.post_merge // 0')
    UNMERGED_COUNT=$(echo "$CLASSIFICATION" | jq -r '.summary.unmerged // 0')
    RECOMMENDATION=$(echo "$CLASSIFICATION" | jq -r '.recommendation // "review"')
    MESSAGE=$(echo "$CLASSIFICATION" | jq -r '.message // ""')

    if [ "$PR_MERGED" = "true" ]; then
      echo -e "${CYAN}PR #$PR_NUMBER was merged${NC}"
      echo ""
    fi

    echo -e "${BLUE}Commit Classification:${NC}"
    if [ "$MERGED_COUNT" -gt 0 ]; then
      echo -e "  ${GREEN}✓ MERGED (in PR):${NC} $MERGED_COUNT commit(s)"
    fi
    if [ "$POST_MERGE_COUNT" -gt 0 ]; then
      echo -e "  ${YELLOW}⚠ POST-MERGE:${NC} $POST_MERGE_COUNT commit(s) - made after PR merged"
    fi
    if [ "$UNMERGED_COUNT" -gt 0 ]; then
      echo -e "  ${RED}✗ UNMERGED:${NC} $UNMERGED_COUNT commit(s) - no PR merged"
    fi
    echo ""

    # Show individual commits with classification
    echo "Commits:"
    echo "$CLASSIFICATION" | jq -r '.commits[] | "  \(.short_sha) [\(.classification)] \(.message)"' 2>/dev/null || echo "$UNPUSHED"
    echo ""

    echo -e "${CYAN}$MESSAGE${NC}"
    echo ""

    # Offer actions based on recommendation
    if [ "$RECOMMENDATION" = "cherry_pick" ] && [ "$POST_MERGE_COUNT" -gt 0 ]; then
      if $AUTO_MODE; then
        # In auto mode, discard post-merge commits with warning
        echo -e "${YELLOW}Auto mode: Discarding $POST_MERGE_COUNT post-merge commit(s)${NC}"
        log_action "CLEANUP_WARNING" "issue=$ISSUE path=$WORKTREE_PATH" "post_merge_commits_auto_discarded"
      else
        echo "Options:"
        echo "  [c] Cherry-pick post-merge commits to new branch"
        echo "  [d] Discard all and continue cleanup"
        echo "  [a] Abort cleanup"
        echo ""
        read -p "Select option (c/d/a): " action
        case "$action" in
          c|C)
            echo ""
            echo "Cherry-picking $POST_MERGE_COUNT post-merge commit(s)..."
            if CHERRY_RESULT=$("$SCRIPT_DIR/worktree-cherry-pick.sh" "$ISSUE" 2>&1); then
              NEW_BRANCH=$(echo "$CHERRY_RESULT" | jq -r '.target_branch // ""')
              PICKED=$(echo "$CHERRY_RESULT" | jq -r '.commits_count // 0')
              echo -e "${GREEN}✓ Cherry-picked $PICKED commit(s) to $NEW_BRANCH${NC}"
              log_action "CHERRY_PICK" "issue=$ISSUE commits=$PICKED branch=$NEW_BRANCH" "success"
              echo ""
              echo "Next steps after cleanup:"
              echo "  - Create PR: gh pr create --base dev --head $NEW_BRANCH"
            else
              echo -e "${RED}Cherry-pick failed. Review manually.${NC}"
              echo "$CHERRY_RESULT"
              read -p "Continue with cleanup anyway? (y/N) " confirm
              if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                log_action "CLEANUP_ABORT" "issue=$ISSUE path=$WORKTREE_PATH" "cherry_pick_failed_user_declined"
                echo "Aborted."
                exit 1
              fi
            fi
            ;;
          d|D)
            echo "Discarding commits and continuing..."
            log_action "CLEANUP_WARNING" "issue=$ISSUE path=$WORKTREE_PATH" "post_merge_commits_discarded"
            ;;
          *)
            log_action "CLEANUP_ABORT" "issue=$ISSUE path=$WORKTREE_PATH" "user_aborted_at_commit_options"
            echo "Aborted."
            exit 1
            ;;
        esac
      fi
    elif [ "$RECOMMENDATION" = "discard" ]; then
      echo -e "${GREEN}All commits were in the merged PR - safe to discard${NC}"
      if $AUTO_MODE; then
        echo "Auto mode: Auto-discarding merged commits"
        log_action "CLEANUP_WARNING" "issue=$ISSUE path=$WORKTREE_PATH" "merged_commits_auto_discarded"
      else
        read -p "Continue with cleanup? (Y/n) " confirm
        if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
          log_action "CLEANUP_ABORT" "issue=$ISSUE path=$WORKTREE_PATH" "safe_discard_user_declined"
          echo "Aborted."
          exit 1
        fi
        log_action "CLEANUP_WARNING" "issue=$ISSUE path=$WORKTREE_PATH" "merged_commits_discarded"
      fi
    else
      # Default: show basic prompt or auto-continue in auto mode
      if $AUTO_MODE; then
        echo -e "${YELLOW}Auto mode: Discarding $UNPUSHED_COUNT unpushed commit(s)${NC}"
        log_action "CLEANUP_WARNING" "issue=$ISSUE path=$WORKTREE_PATH" "unpushed_commits_auto_discarded"
      else
        read -p "Continue with cleanup? (y/N) " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
          log_action "CLEANUP_ABORT" "issue=$ISSUE path=$WORKTREE_PATH" "unpushed_commits_user_declined"
          echo "Aborted."
          exit 1
        fi
        log_action "CLEANUP_WARNING" "issue=$ISSUE path=$WORKTREE_PATH" "unpushed_commits_user_confirmed"
      fi
    fi
  else
    # Fallback to basic display if classification fails
    echo "Unpushed commits:"
    echo "$UNPUSHED"
    echo ""
    if $AUTO_MODE; then
      echo -e "${YELLOW}Auto mode: Discarding $UNPUSHED_COUNT unpushed commit(s) (classification unavailable)${NC}"
      log_action "CLEANUP_WARNING" "issue=$ISSUE path=$WORKTREE_PATH" "unpushed_commits_auto_discarded_no_classification"
    else
      read -p "Continue anyway? (y/N) " confirm
      if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_action "CLEANUP_ABORT" "issue=$ISSUE path=$WORKTREE_PATH" "unpushed_commits_user_declined"
        echo "Aborted."
        exit 1
      fi
      log_action "CLEANUP_WARNING" "issue=$ISSUE path=$WORKTREE_PATH" "unpushed_commits_user_confirmed"
    fi
  fi
fi

# Remove worktree
echo "Removing worktree..."
git worktree remove "$WORKTREE_PATH" --force

log_action "WORKTREE_REMOVED" "issue=$ISSUE path=$WORKTREE_PATH" "success"
echo -e "${GREEN}✓ Worktree removed${NC}"

# Optionally delete branch
BRANCH_DELETED=false
if [ "$DELETE_BRANCH" = true ] && [ -n "$BRANCH" ]; then
  echo "Deleting local branch: $BRANCH..."

  # Check if branch is merged
  if git branch --merged | grep -q "$BRANCH"; then
    git branch -d "$BRANCH"
    log_action "BRANCH_DELETED" "issue=$ISSUE branch=$BRANCH" "merged_branch_deleted"
    echo -e "${GREEN}✓ Branch deleted${NC}"
    BRANCH_DELETED=true
  else
    if $AUTO_MODE; then
      # Auto mode: force delete
      git branch -D "$BRANCH"
      log_action "BRANCH_DELETED" "issue=$ISSUE branch=$BRANCH" "auto_force_deleted"
      echo -e "${GREEN}✓ Branch force deleted (auto mode)${NC}"
      BRANCH_DELETED=true
    else
      echo -e "${YELLOW}Branch not merged. Force delete? (y/N)${NC}"
      read -p "" confirm
      if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        git branch -D "$BRANCH"
        log_action "BRANCH_DELETED" "issue=$ISSUE branch=$BRANCH" "force_deleted"
        echo -e "${GREEN}✓ Branch force deleted${NC}"
        BRANCH_DELETED=true
      else
        log_action "BRANCH_KEPT" "issue=$ISSUE branch=$BRANCH" "user_declined_force_delete"
        echo "Branch kept."
      fi
    fi
  fi
fi

# Prune stale references
git worktree prune

log_action "CLEANUP_COMPLETE" "issue=$ISSUE path=$WORKTREE_PATH branch_deleted=$BRANCH_DELETED" "success"

# Output JSON if requested
if $JSON_OUTPUT; then
  cat << EOF
{
  "success": true,
  "issue": $ISSUE,
  "action": "cleaned",
  "worktree_removed": true,
  "branch": "$BRANCH",
  "branch_deleted": $BRANCH_DELETED,
  "message": "Worktree cleaned up successfully"
}
EOF
else
  echo ""
  echo -e "${GREEN}Cleanup complete for issue #$ISSUE${NC}"
  echo ""
  echo "Audit log: $LOG_FILE"
  echo ""
  echo "Next steps:"
  echo "  - Verify PR is merged: gh pr view --head $BRANCH"
  echo "  - Delete remote branch if needed: git push origin --delete $BRANCH"
fi
