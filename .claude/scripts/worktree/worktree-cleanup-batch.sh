#!/bin/bash
set -euo pipefail
# worktree-cleanup-batch.sh
# Cleans up multiple worktrees in a single script execution
#
# This script reduces token usage by processing multiple worktree cleanups
# in one bash invocation instead of N separate calls.
#
# Usage:
#   ./scripts/worktree-cleanup-batch.sh 15,21,29,30
#   ./scripts/worktree-cleanup-batch.sh 15,21,29 --delete-branches
#   ./scripts/worktree-cleanup-batch.sh 15,21,29 --force
#   ./scripts/worktree-cleanup-batch.sh 15,21,29 --dry-run
#
# Options:
#   --delete-branches   Also delete local branches after removing worktrees
#   --force             Force cleanup even for worktrees with conflicts
#   --dry-run           Show what would be done without making changes
#
# Returns JSON:
#   {
#     "success": true,
#     "cleaned": [15, 21, 29],
#     "skipped": [{"issue": 30, "reason": "uncommitted changes"}],
#     "errors": [],
#     "summary": "Cleaned 3 worktrees, skipped 1"
#   }
#
# Must be run from the main repository (not a worktree)
#
# Audit Logging:
#   Location: ~/.claude-tastic/logs/worktree-cleanup.log

set -e

# DEPRECATION NOTICE: Worktree scripts are being phased out in favor of container-based
# execution. See docs/CONTAINERIZED_WORKFLOW.md#worktree-deprecation-timeline for timeline.
# Use: /sprint-work --issue N --container
echo "DEPRECATION: worktree-cleanup-batch.sh will be removed in Phase 3. Use container mode instead." >&2

# Colors for output (only used in non-JSON mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source framework config to get FRAMEWORK_LOG_DIR
source "${SCRIPT_DIR}/lib/framework-config.sh"

# Audit log configuration
LOG_DIR="${FRAMEWORK_LOG_DIR}"
LOG_FILE="${LOG_DIR}/worktree-cleanup.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Parse arguments
ISSUES=""
DELETE_BRANCHES=false
FORCE=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --delete-branches)
      DELETE_BRANCHES=true
      ;;
    --force)
      FORCE=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --help|-h)
      echo "Usage: $0 <issue1,issue2,...> [--delete-branches] [--force] [--dry-run]"
      echo ""
      echo "Clean up multiple worktrees in a single script execution."
      echo ""
      echo "Arguments:"
      echo "  <issues>           Comma-separated list of issue numbers"
      echo ""
      echo "Options:"
      echo "  --delete-branches  Also delete local branches"
      echo "  --force            Force cleanup even with conflicts"
      echo "  --dry-run          Show what would be done"
      echo ""
      echo "Example:"
      echo "  $0 15,21,29,30 --delete-branches"
      exit 0
      ;;
    *)
      # First non-flag argument is the issues list
      if [ -z "$ISSUES" ]; then
        ISSUES="$arg"
      fi
      ;;
  esac
done

if [ -z "$ISSUES" ]; then
  echo '{"success": false, "error": "No issue numbers provided", "usage": "./scripts/worktree-cleanup-batch.sh 15,21,29"}'
  exit 1
fi

# Check if in main repo
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ ! -d "$TOPLEVEL/.git" ]; then
  echo '{"success": false, "error": "Must run from main repository, not a worktree"}'
  exit 1
fi

REPO_NAME=$(basename "$TOPLEVEL")
PARENT_DIR=$(dirname "$TOPLEVEL")

# Logging function
log_action() {
  local action="$1"
  local details="$2"
  local outcome="$3"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local user=$(whoami)
  local repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

  echo "${timestamp}|${user}|${repo_name}|${action}|${details}|${outcome}" >> "$LOG_FILE" 2>/dev/null || true
}

# Initialize result arrays
CLEANED=()
SKIPPED=()
ERRORS=()

# Split issues by comma
IFS=',' read -ra ISSUE_ARRAY <<< "$ISSUES"

log_action "BATCH_CLEANUP_START" "issues=${ISSUES} force=${FORCE} dry_run=${DRY_RUN}" "initiated"

for ISSUE in "${ISSUE_ARRAY[@]}"; do
  # Trim whitespace
  ISSUE=$(echo "$ISSUE" | tr -d ' ')

  # Skip empty entries
  [ -z "$ISSUE" ] && continue

  WORKTREE_PATH="$PARENT_DIR/${REPO_NAME}-issue-$ISSUE"

  # Check if worktree exists
  if [ ! -d "$WORKTREE_PATH" ]; then
    SKIPPED+=("{\"issue\": $ISSUE, \"reason\": \"worktree not found\"}")
    continue
  fi

  # Get branch name
  BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current 2>/dev/null || echo "")

  # Check for conflicts
  HAS_UNCOMMITTED=false
  HAS_UNPUSHED=false
  CONFLICT_REASON=""

  # Check for uncommitted changes
  if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null)" ]; then
    HAS_UNCOMMITTED=true
    CONFLICT_REASON="uncommitted changes"
  fi

  # Check for unpushed commits (only if upstream exists)
  if git -C "$WORKTREE_PATH" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    UNPUSHED_COUNT=$(git -C "$WORKTREE_PATH" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$UNPUSHED_COUNT" -gt 0 ]; then
      HAS_UNPUSHED=true
      if [ -n "$CONFLICT_REASON" ]; then
        CONFLICT_REASON="$CONFLICT_REASON, $UNPUSHED_COUNT unpushed commits"
      else
        CONFLICT_REASON="$UNPUSHED_COUNT unpushed commits"
      fi
    fi
  fi

  # Skip if conflicts and not forcing
  if [ -n "$CONFLICT_REASON" ] && [ "$FORCE" = false ]; then
    SKIPPED+=("{\"issue\": $ISSUE, \"reason\": \"$CONFLICT_REASON\"}")
    continue
  fi

  # Dry run mode
  if [ "$DRY_RUN" = true ]; then
    if [ -n "$CONFLICT_REASON" ]; then
      echo "Would force cleanup: issue #$ISSUE (has $CONFLICT_REASON)" >&2
    else
      echo "Would cleanup: issue #$ISSUE" >&2
    fi
    CLEANED+=("$ISSUE")
    continue
  fi

  # Perform cleanup
  if git worktree remove "$WORKTREE_PATH" --force 2>/dev/null; then
    log_action "WORKTREE_REMOVED" "issue=$ISSUE path=$WORKTREE_PATH" "success"

    # Optionally delete branch
    if [ "$DELETE_BRANCHES" = true ] && [ -n "$BRANCH" ]; then
      if git branch -D "$BRANCH" 2>/dev/null; then
        log_action "BRANCH_DELETED" "issue=$ISSUE branch=$BRANCH" "success"
      fi
    fi

    CLEANED+=("$ISSUE")
  else
    ERRORS+=("{\"issue\": $ISSUE, \"error\": \"failed to remove worktree\"}")
    log_action "CLEANUP_ERROR" "issue=$ISSUE path=$WORKTREE_PATH" "failed"
  fi
done

# Prune stale worktree references
git worktree prune 2>/dev/null || true

# Build JSON output
CLEANED_JSON=$(printf '%s\n' "${CLEANED[@]}" | jq -R . | jq -s .)
SKIPPED_JSON=$(printf '%s\n' "${SKIPPED[@]}" | jq -s '.')
ERRORS_JSON=$(printf '%s\n' "${ERRORS[@]}" | jq -s '.')

# Handle empty arrays
[ -z "$CLEANED_JSON" ] || [ "$CLEANED_JSON" = "null" ] && CLEANED_JSON="[]"
[ -z "$SKIPPED_JSON" ] || [ "$SKIPPED_JSON" = "null" ] && SKIPPED_JSON="[]"
[ -z "$ERRORS_JSON" ] || [ "$ERRORS_JSON" = "null" ] && ERRORS_JSON="[]"

CLEANED_COUNT=${#CLEANED[@]}
SKIPPED_COUNT=${#SKIPPED[@]}
ERRORS_COUNT=${#ERRORS[@]}

SUMMARY="Cleaned $CLEANED_COUNT worktrees"
[ "$SKIPPED_COUNT" -gt 0 ] && SUMMARY="$SUMMARY, skipped $SKIPPED_COUNT"
[ "$ERRORS_COUNT" -gt 0 ] && SUMMARY="$SUMMARY, $ERRORS_COUNT errors"

log_action "BATCH_CLEANUP_COMPLETE" "cleaned=$CLEANED_COUNT skipped=$SKIPPED_COUNT errors=$ERRORS_COUNT" "completed"

# Output JSON result
jq -n \
  --argjson cleaned "$CLEANED_JSON" \
  --argjson skipped "$SKIPPED_JSON" \
  --argjson errors "$ERRORS_JSON" \
  --arg summary "$SUMMARY" \
  --argjson dry_run "$DRY_RUN" \
  '{
    success: (($errors | length) == 0),
    dry_run: $dry_run,
    cleaned: ($cleaned | map(tonumber)),
    skipped: $skipped,
    errors: $errors,
    summary: $summary
  }'
