#!/bin/bash
set -euo pipefail
# resolve-pr-conflicts.sh
# Automates PR conflict resolution workflow
#
# Usage:
#   ./scripts/resolve-pr-conflicts.sh <PR#> [OPTIONS]
#
# Options:
#   --auto           Non-interactive mode (use default strategies)
#   --strategy       Conflict strategy: ours|theirs|manual (default: manual)
#   --close-if-empty Auto-close PR if all commits already upstream
#   --dry-run        Show what would be done
#
# Output: JSON with resolution result

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Custom logging aliases for this script (uses CYAN for info)
log_warning() {
  log_warn "$@"
}

# Defaults
PR_NUMBER=""
AUTO_MODE=false
STRATEGY="manual"
CLOSE_IF_EMPTY=false
DRY_RUN=false

# State tracking for cleanup
ORIGINAL_BRANCH=""
STASH_CREATED=false
STASH_REF=""
PR_BRANCH=""
CHECKOUT_PERFORMED=false

# Cleanup function - ensures we return to original state
cleanup() {
  local exit_code=$?

  # Return to original branch if we checked out PR branch
  if $CHECKOUT_PERFORMED && [ -n "$ORIGINAL_BRANCH" ]; then
    log_info "Returning to original branch: $ORIGINAL_BRANCH"
    git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
  fi

  # Restore stash if we created one
  if $STASH_CREATED && [ -n "$STASH_REF" ]; then
    log_info "Restoring stashed changes"
    git stash pop "$STASH_REF" 2>/dev/null || {
      log_warning "Could not pop stash, changes saved as: $STASH_REF"
    }
  fi

  exit $exit_code
}

trap cleanup EXIT

# Output JSON result (stdout)
output_json() {
  local success="$1"
  local action="$2"
  local message="$3"
  local extra="$4"

  cat << EOF
{
  "success": $success,
  "action": "$action",
  "message": "$message",
  "pr_number": $PR_NUMBER,
  "strategy": "$STRATEGY"${extra:+,
  $extra}
}
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --auto)
      AUTO_MODE=true
      shift
      ;;
    --strategy)
      STRATEGY="$2"
      if [[ ! "$STRATEGY" =~ ^(ours|theirs|manual)$ ]]; then
        log_error "Invalid strategy: $STRATEGY (must be: ours|theirs|manual)"
        exit 1
      fi
      shift 2
      ;;
    --close-if-empty)
      CLOSE_IF_EMPTY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 <PR#> [OPTIONS]"
      echo ""
      echo "Automates PR conflict resolution workflow."
      echo ""
      echo "Options:"
      echo "  --auto           Non-interactive mode (use default strategies)"
      echo "  --strategy STR   Conflict strategy: ours|theirs|manual (default: manual)"
      echo "  --close-if-empty Auto-close PR if all commits already upstream"
      echo "  --dry-run        Show what would be done"
      echo ""
      echo "Workflow:"
      echo "  1. Save current branch and stash local changes"
      echo "  2. Fetch PR branch and base branch"
      echo "  3. Checkout PR branch"
      echo "  4. Check if all commits are already in base"
      echo "  5. If empty: close PR with comment (if --close-if-empty)"
      echo "  6. Attempt rebase onto base"
      echo "  7. If conflicts: apply strategy or prompt"
      echo "  8. Force push rebased branch"
      echo "  9. Return to original branch"
      echo " 10. Restore stashed changes"
      exit 0
      ;;
    *)
      if [[ -z "$PR_NUMBER" && "$1" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$1"
      else
        log_error "Unknown argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate PR number
if [[ -z "$PR_NUMBER" ]]; then
  log_error "PR number required"
  echo "Usage: $0 <PR#> [OPTIONS]" >&2
  exit 1
fi

# Get repo info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || {
  log_error "Could not determine repository"
  output_json "false" "error" "Could not determine repository"
  exit 1
}

log_info "Repository: $REPO"
log_info "PR: #$PR_NUMBER"

# Step 1: Save current branch and stash local changes
ORIGINAL_BRANCH=$(git branch --show-current 2>/dev/null)
if [ -z "$ORIGINAL_BRANCH" ]; then
  log_error "Not on a branch (detached HEAD state)"
  output_json "false" "error" "Not on a branch"
  exit 1
fi

log_info "Original branch: $ORIGINAL_BRANCH"

# Check for uncommitted changes
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  log_info "Stashing local changes..."
  if $DRY_RUN; then
    log_info "[DRY-RUN] Would stash local changes"
  else
    STASH_REF=$(git stash create "resolve-pr-conflicts: PR #$PR_NUMBER")
    if [ -n "$STASH_REF" ]; then
      git stash store -m "resolve-pr-conflicts: PR #$PR_NUMBER" "$STASH_REF"
      STASH_CREATED=true
      log_success "Changes stashed: $STASH_REF"
    fi
  fi
fi

# Step 2: Fetch PR details and branches
log_info "Fetching PR details..."

PR_INFO=$(gh pr view "$PR_NUMBER" --json headRefName,baseRefName,state,commits 2>/dev/null) || {
  log_error "Could not fetch PR #$PR_NUMBER"
  output_json "false" "error" "Could not fetch PR #$PR_NUMBER"
  exit 1
}

PR_STATE=$(echo "$PR_INFO" | jq -r '.state')
PR_BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName')
BASE_BRANCH=$(echo "$PR_INFO" | jq -r '.baseRefName')
COMMIT_COUNT=$(echo "$PR_INFO" | jq '.commits | length')

log_info "PR state: $PR_STATE"
log_info "PR branch: $PR_BRANCH"
log_info "Base branch: $BASE_BRANCH"
log_info "Commits in PR: $COMMIT_COUNT"

# Validate PR is open
if [[ "$PR_STATE" != "OPEN" ]]; then
  log_error "PR #$PR_NUMBER is not open (state: $PR_STATE)"
  output_json "false" "error" "PR is not open (state: $PR_STATE)"
  exit 1
fi

# Fetch remote branches
log_info "Fetching remote branches..."
if $DRY_RUN; then
  log_info "[DRY-RUN] Would fetch origin"
else
  git fetch origin "$PR_BRANCH" "$BASE_BRANCH" 2>/dev/null || {
    log_error "Failed to fetch branches"
    output_json "false" "error" "Failed to fetch branches"
    exit 1
  }
fi

# Step 3: Check if all commits are already in base
log_info "Checking for commits not in base..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would check commits between origin/$BASE_BRANCH..origin/$PR_BRANCH"
  UNIQUE_COMMITS=1  # Assume non-empty for dry-run
else
  # Count commits in PR branch not in base branch
  UNIQUE_COMMITS=$(git log --oneline "origin/$BASE_BRANCH..origin/$PR_BRANCH" 2>/dev/null | wc -l | tr -d ' ')
fi

log_info "Unique commits not in base: $UNIQUE_COMMITS"

# Step 4: Handle empty PR (all commits already upstream)
if [[ "$UNIQUE_COMMITS" -eq 0 ]]; then
  log_warning "All commits in PR are already in $BASE_BRANCH"

  if $CLOSE_IF_EMPTY; then
    log_info "Closing PR (--close-if-empty specified)..."

    if $DRY_RUN; then
      log_info "[DRY-RUN] Would close PR #$PR_NUMBER with comment"
      output_json "true" "closed" "PR would be closed (all commits already upstream)" '"dry_run": true'
    else
      CLOSE_COMMENT="This PR has been automatically closed because all commits are already present in \`$BASE_BRANCH\`.

This typically happens when:
- The same changes were merged via another PR
- A manual merge was performed
- The branch was rebased after the target branch incorporated the changes

No action is required. The changes are already in the target branch."

      gh pr close "$PR_NUMBER" --comment "$CLOSE_COMMENT" || {
        log_error "Failed to close PR"
        output_json "false" "error" "Failed to close PR"
        exit 1
      }

      log_success "PR #$PR_NUMBER closed (all commits already upstream)"
      output_json "true" "closed" "PR closed - all commits already upstream"
    fi
  else
    log_info "PR has no unique commits. Use --close-if-empty to auto-close."
    output_json "true" "empty" "PR has no unique commits (use --close-if-empty to auto-close)"
  fi
  exit 0
fi

# Step 5: Checkout PR branch
log_info "Checking out PR branch: $PR_BRANCH"

if $DRY_RUN; then
  log_info "[DRY-RUN] Would checkout origin/$PR_BRANCH"
else
  # Create local tracking branch or update existing
  git checkout -B "$PR_BRANCH" "origin/$PR_BRANCH" 2>/dev/null || {
    log_error "Failed to checkout PR branch"
    output_json "false" "error" "Failed to checkout PR branch"
    exit 1
  }
  CHECKOUT_PERFORMED=true
  log_success "Checked out $PR_BRANCH"
fi

# Step 6: Attempt rebase onto base
log_info "Attempting rebase onto $BASE_BRANCH..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would rebase onto origin/$BASE_BRANCH"
  output_json "true" "dry_run" "Rebase would be attempted" '"dry_run": true'
  exit 0
fi

# Try rebase
REBASE_OUTPUT=""
REBASE_SUCCESS=false

if git rebase "origin/$BASE_BRANCH" 2>&1; then
  REBASE_SUCCESS=true
  log_success "Rebase completed successfully"
else
  REBASE_OUTPUT=$(git status 2>&1)
  log_warning "Rebase encountered conflicts"

  # Step 7: Handle conflicts based on strategy
  case $STRATEGY in
    ours)
      log_info "Applying 'ours' strategy (keeping PR changes)..."
      # For each conflicted file, use ours (the rebasing branch's version)
      git diff --name-only --diff-filter=U | while read -r file; do
        git checkout --ours "$file" 2>/dev/null && git add "$file"
      done

      if git rebase --continue 2>/dev/null; then
        REBASE_SUCCESS=true
        log_success "Conflicts resolved using 'ours' strategy"
      else
        log_error "Failed to complete rebase with 'ours' strategy"
        git rebase --abort 2>/dev/null
        output_json "false" "conflict" "Failed to resolve conflicts with ours strategy"
        exit 1
      fi
      ;;

    theirs)
      log_info "Applying 'theirs' strategy (keeping base changes)..."
      # For each conflicted file, use theirs (the base branch's version)
      git diff --name-only --diff-filter=U | while read -r file; do
        git checkout --theirs "$file" 2>/dev/null && git add "$file"
      done

      if git rebase --continue 2>/dev/null; then
        REBASE_SUCCESS=true
        log_success "Conflicts resolved using 'theirs' strategy"
      else
        log_error "Failed to complete rebase with 'theirs' strategy"
        git rebase --abort 2>/dev/null
        output_json "false" "conflict" "Failed to resolve conflicts with theirs strategy"
        exit 1
      fi
      ;;

    manual)
      if $AUTO_MODE; then
        log_error "Conflicts require manual resolution but --auto was specified"
        git rebase --abort 2>/dev/null
        output_json "false" "conflict" "Conflicts require manual resolution" '"conflicts": true'
        exit 1
      fi

      # List conflicted files
      CONFLICTED_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ', ' | sed 's/,$//')

      log_warning "Manual resolution required for: $CONFLICTED_FILES"
      log_info "Options:"
      log_info "  1. Resolve conflicts manually, then run: git add . && git rebase --continue"
      log_info "  2. Abort and try different strategy: git rebase --abort"
      log_info "  3. Use --strategy ours|theirs for automatic resolution"

      git rebase --abort 2>/dev/null
      output_json "false" "manual_required" "Manual conflict resolution required" "\"conflicted_files\": \"$CONFLICTED_FILES\""
      exit 1
      ;;
  esac
fi

# Step 8: Force push rebased branch
if $REBASE_SUCCESS; then
  log_info "Force pushing rebased branch..."

  if git push origin "$PR_BRANCH" --force-with-lease 2>&1; then
    log_success "Branch $PR_BRANCH force-pushed successfully"

    # Get new commit info
    NEW_HEAD=$(git rev-parse HEAD)

    output_json "true" "rebased" "PR rebased and pushed successfully" "\"new_head\": \"$NEW_HEAD\", \"unique_commits\": $UNIQUE_COMMITS"
  else
    log_error "Failed to push rebased branch"
    output_json "false" "push_failed" "Rebase succeeded but push failed"
    exit 1
  fi
fi
