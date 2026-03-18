#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: auto-cleanup-merged.sh
# Purpose: Automatically cleanup worktrees/containers for merged PRs
# Usage: ./scripts/auto-cleanup-merged.sh [OPTIONS]
#
# This script checks for PRs that have been merged and automatically
# cleans up their associated worktrees or containers if they were
# registered with --cleanup-after-merge.
#
# Can be run:
# - Manually by the user
# - From post-merge git hook
# - From a cron job or scheduled task
#
# Issue: #104 - Add --cleanup-after-merge flag to PR creation
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities and cleanup tracking
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/cleanup-tracking.sh"

# Usage
usage() {
  cat << EOF
auto-cleanup-merged.sh - Auto-cleanup worktrees/containers for merged PRs

USAGE:
    auto-cleanup-merged.sh [OPTIONS]

OPTIONS:
    --all                       Check all pending cleanups
    --issue <N>                 Cleanup specific issue if merged
    --dry-run                   Show what would be cleaned without doing it
    --force                     Skip confirmation prompts
    --prune                     Remove old completed entries (>30 days)
    --list                      List pending cleanups and exit
    --help                      Show this help

EXAMPLES:
    # Check all pending cleanups and cleanup merged PRs
    auto-cleanup-merged.sh --all

    # Check specific issue
    auto-cleanup-merged.sh --issue 104

    # Dry run to see what would be cleaned
    auto-cleanup-merged.sh --all --dry-run

    # Cleanup all merged PRs without prompts
    auto-cleanup-merged.sh --all --force

    # List pending cleanups
    auto-cleanup-merged.sh --list

NOTES:
    - Only cleans up PRs that were created with --cleanup-after-merge
    - Checks GitHub to verify PR is actually merged before cleanup
    - For worktrees: Runs worktree-cleanup.sh with --delete-branch
    - For containers: Runs container-cleanup.sh
    - Tracking file: $FRAMEWORK_DIR/pending-cleanup.json (default: ~/.claude-agent/pending-cleanup.json)

EOF
}

# Check if a PR is merged
# Args: pr_number
# Returns: 0 if merged, 1 if not merged or error
is_pr_merged() {
  local pr="$1"

  if ! command -v gh &> /dev/null; then
    log_warn "gh CLI not available - cannot check PR status"
    return 1
  fi

  local state
  state=$(gh pr view "$pr" --json state,merged --jq '.state + ":" + (.merged | tostring)' 2>/dev/null || echo "")

  if [ "$state" = "MERGED:true" ]; then
    return 0
  fi

  return 1
}

# Cleanup a worktree
# Args: issue worktree_path dry_run force
cleanup_worktree() {
  local issue="$1"
  local worktree_path="$2"
  local dry_run="$3"
  local force="$4"

  if [ "$dry_run" = true ]; then
    log_info "[DRY-RUN] Would cleanup worktree: $worktree_path"
    return 0
  fi

  # Check if worktree exists
  if [ ! -d "$worktree_path" ]; then
    log_warn "Worktree not found: $worktree_path"
    log_info "Marking cleanup as completed anyway"
    complete_cleanup "$issue"
    return 0
  fi

  log_info "Cleaning up worktree: $worktree_path"

  if [ -x "$SCRIPT_DIR/worktree/worktree-cleanup.sh" ]; then
    local cleanup_args=("$issue" "--delete-branch")
    if [ "$force" = true ]; then
      cleanup_args+=("--auto")
    fi

    "$SCRIPT_DIR/worktree/worktree-cleanup.sh" "${cleanup_args[@]}"
    complete_cleanup "$issue"
    log_success "Worktree cleanup completed for issue #$issue"
  else
    log_error "worktree-cleanup.sh not found at $SCRIPT_DIR/worktree/worktree-cleanup.sh"
    log_info "Manual cleanup required:"
    log_info "  cd $(dirname "$worktree_path")"
    log_info "  ./scripts/worktree/worktree-cleanup.sh $issue --delete-branch"
    return 1
  fi
}

# Cleanup a container
# Args: issue dry_run force
cleanup_container() {
  local issue="$1"
  local dry_run="$2"
  local force="$3"

  if [ "$dry_run" = true ]; then
    log_info "[DRY-RUN] Would cleanup container for issue #$issue"
    return 0
  fi

  log_info "Cleaning up container for issue #$issue"

  if [ -x "$SCRIPT_DIR/container/container-cleanup.sh" ]; then
    local cleanup_args=("--issue" "$issue")
    if [ "$force" = true ]; then
      cleanup_args+=("--force")
    fi

    "$SCRIPT_DIR/container/container-cleanup.sh" "${cleanup_args[@]}" || true
    complete_cleanup "$issue"
    log_success "Container cleanup completed for issue #$issue"
  else
    log_error "container-cleanup.sh not found at $SCRIPT_DIR/container/container-cleanup.sh"
    log_info "Manual cleanup required:"
    log_info "  ./scripts/container/container-cleanup.sh --issue $issue"
    return 1
  fi
}

# Process a single cleanup entry
# Args: dry_run force
process_cleanup() {
  local entry="$1"
  local dry_run="$2"
  local force="$3"

  local issue pr branch worktree_path mode
  issue=$(echo "$entry" | jq -r '.issue')
  pr=$(echo "$entry" | jq -r '.pr // ""')
  branch=$(echo "$entry" | jq -r '.branch')
  worktree_path=$(echo "$entry" | jq -r '.worktree_path // ""')
  mode=$(echo "$entry" | jq -r '.mode // "worktree"')

  log_info "Processing cleanup for issue #$issue (PR #$pr, mode: $mode)"

  # Check if PR is merged
  if [ -n "$pr" ]; then
    if ! is_pr_merged "$pr"; then
      log_info "PR #$pr not yet merged - skipping cleanup"
      return 0
    fi
    log_info "PR #$pr is merged - proceeding with cleanup"
  else
    log_warn "No PR number tracked - cannot verify merge status"
    if [ "$force" = false ]; then
      echo -n "Cleanup anyway? [y/N] "
      read -r response </dev/tty
      if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
        log_info "Skipping cleanup for issue #$issue"
        return 0
      fi
    fi
  fi

  # Perform cleanup based on mode
  case "$mode" in
    worktree)
      cleanup_worktree "$issue" "$worktree_path" "$dry_run" "$force"
      ;;
    container)
      cleanup_container "$issue" "$dry_run" "$force"
      ;;
    *)
      log_error "Unknown mode: $mode"
      return 1
      ;;
  esac
}

# List pending cleanups
list_cleanups() {
  local pending
  pending=$(list_pending_cleanups)

  if [ -z "$pending" ]; then
    echo "No pending cleanups"
    return 0
  fi

  echo ""
  echo "Pending Cleanups:"
  echo "================"
  echo ""

  printf "%-8s %-8s %-12s %-40s %s\n" "ISSUE" "PR" "MODE" "BRANCH" "ADDED"
  printf "%-8s %-8s %-12s %-40s %s\n" "-----" "--" "----" "------" "-----"

  echo "$pending" | jq -r '
    [.issue, .pr // "-", .mode, .branch, .added_at] | @tsv
  ' | while IFS=$'\t' read -r issue pr mode branch added; do
    printf "%-8s %-8s %-12s %-40s %s\n" "#$issue" "#$pr" "$mode" "$branch" "$added"
  done

  echo ""
}

# Main function
main() {
  local action=""
  local issue=""
  local dry_run=false
  local force=false

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)
        action="all"
        shift
        ;;
      --issue)
        action="issue"
        issue="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --force)
        force=true
        shift
        ;;
      --prune)
        action="prune"
        shift
        ;;
      --list)
        action="list"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  # Ensure tracking file exists
  ensure_tracking_file

  # Execute action
  case "$action" in
    all)
      log_info "Checking all pending cleanups..."
      echo ""

      local pending
      pending=$(list_pending_cleanups)

      if [ -z "$pending" ]; then
        log_info "No pending cleanups"
        exit 0
      fi

      local count=0
      local cleaned=0

      while read -r entry; do
        ((count++))
        echo ""
        echo "─────────────────────────────────────────────────────────────"
        if process_cleanup "$entry" "$dry_run" "$force"; then
          ((cleaned++))
        fi
      done < <(echo "$pending" | jq -c '.')

      echo ""
      echo "─────────────────────────────────────────────────────────────"
      echo ""
      log_success "Processed $count pending cleanup(s), cleaned $cleaned"
      ;;

    issue)
      if [ -z "$issue" ]; then
        log_error "--issue requires an issue number"
        exit 1
      fi

      log_info "Checking cleanup for issue #$issue..."

      if ! has_cleanup_intent "$issue"; then
        log_warn "No cleanup intent found for issue #$issue"
        log_info "Issue was not created with --cleanup-after-merge"
        exit 0
      fi

      local entry
      entry=$(get_cleanup_entry "$issue")

      if [ -z "$entry" ]; then
        log_warn "No pending cleanup found for issue #$issue"
        exit 0
      fi

      process_cleanup "$entry" "$dry_run" "$force"
      ;;

    prune)
      log_info "Pruning old completed entries..."
      prune_old_entries
      log_success "Pruning complete"
      ;;

    list)
      list_cleanups
      ;;

    *)
      log_error "No action specified"
      echo ""
      usage
      exit 1
      ;;
  esac
}

# Run main
main "$@"
