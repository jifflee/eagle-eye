#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: pr-create-with-cleanup.sh
# Purpose: Create PR with optional auto-cleanup tracking
# Usage: ./scripts/pr-create-with-cleanup.sh [OPTIONS]
#
# This script wraps 'gh pr create' and optionally registers
# the PR for automatic cleanup after merge.
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
pr-create-with-cleanup.sh - Create PR with auto-cleanup tracking

USAGE:
    pr-create-with-cleanup.sh [OPTIONS] [GH_PR_CREATE_ARGS...]

OPTIONS:
    --cleanup-after-merge       Register PR for auto-cleanup after merge
    --issue <N>                 Issue number (auto-detected from branch if not provided)
    --worktree-path <PATH>      Worktree path (auto-detected if not provided)
    --help                      Show this help

GH_PR_CREATE_ARGS:
    Any valid 'gh pr create' arguments (--base, --title, --body, etc.)

EXAMPLES:
    # Create PR with auto-cleanup
    pr-create-with-cleanup.sh --cleanup-after-merge --base dev --fill

    # Create PR without auto-cleanup (standard gh pr create)
    pr-create-with-cleanup.sh --base dev --fill

    # Create PR for specific issue with auto-cleanup
    pr-create-with-cleanup.sh --cleanup-after-merge --issue 104 --base dev --fill

NOTES:
    - If --cleanup-after-merge is specified, the PR/issue will be tracked in
      $FRAMEWORK_DIR/pending-cleanup.json (default: ~/.claude-agent/pending-cleanup.json)
    - After the PR is merged, run './scripts/auto-cleanup-merged.sh' or wait
      for the post-merge hook to trigger cleanup automatically
    - Auto-cleanup removes the worktree and optionally deletes the branch

EOF
}

# Parse arguments
CLEANUP_ENABLED=false
ISSUE=""
WORKTREE_PATH=""
GH_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup-after-merge)
      CLEANUP_ENABLED=true
      shift
      ;;
    --issue)
      ISSUE="$2"
      shift 2
      ;;
    --worktree-path)
      WORKTREE_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      # Pass through to gh pr create
      GH_ARGS+=("$1")
      shift
      ;;
  esac
done

# Get current branch
BRANCH=$(git branch --show-current 2>/dev/null)
if [ -z "$BRANCH" ]; then
  log_error "Not on a git branch"
  exit 1
fi

# Auto-detect issue from branch if not provided
if [ -z "$ISSUE" ]; then
  ISSUE=$(echo "$BRANCH" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+' || echo "")
fi

# Auto-detect worktree path if not provided and cleanup is enabled
if [ "$CLEANUP_ENABLED" = true ] && [ -z "$WORKTREE_PATH" ]; then
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ ! -d "$TOPLEVEL/.git" ]; then
    # We're in a worktree (.git is a file, not a directory)
    WORKTREE_PATH="$TOPLEVEL"
  fi
fi

# Determine execution mode (worktree vs container)
MODE="worktree"
if [ -f "/.dockerenv" ] || [ "$CLAUDE_CONTAINER_MODE" = "true" ]; then
  MODE="container"
fi

# Create PR using gh
log_info "Creating PR..."
echo ""

# Run gh pr create with provided arguments
set +e
PR_OUTPUT=$(gh pr create "${GH_ARGS[@]}" 2>&1)
GH_EXIT=$?
set -e

if [ $GH_EXIT -ne 0 ]; then
  log_error "Failed to create PR"
  echo "$PR_OUTPUT"
  exit $GH_EXIT
fi

echo "$PR_OUTPUT"

# Extract PR URL and number
PR_URL=$(echo "$PR_OUTPUT" | grep -oE 'https://github.com/[^/]+/[^/]+/pull/[0-9]+' | head -1)
if [ -z "$PR_URL" ]; then
  log_warn "Could not extract PR URL from output"
  exit 0
fi

PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')

log_success "PR #$PR_NUMBER created: $PR_URL"

# Run cross-reference check against open issues (Issue #1271)
# Skip if NO_CROSS_REF=true or --no-cross-ref was passed through GH_ARGS
if [ "${NO_CROSS_REF:-false}" != "true" ] && ! printf '%s\n' "${GH_ARGS[@]}" | grep -q -- '--no-cross-ref'; then
  XREF_SCRIPT="${SCRIPT_DIR}/pr-cross-reference.sh"
  if [ -f "$XREF_SCRIPT" ] && [ -x "$XREF_SCRIPT" ] && [ -n "$ISSUE" ]; then
    log_info "Running cross-reference check on open issues..."
    "$XREF_SCRIPT" \
      --pr "$PR_NUMBER" \
      --issue "$ISSUE" \
      2>/dev/null || log_warn "Cross-reference check failed (non-fatal)"
  fi
fi

# Register for auto-cleanup if requested
if [ "$CLEANUP_ENABLED" = true ]; then
  if [ -z "$ISSUE" ]; then
    log_warn "Could not detect issue number from branch '$BRANCH'"
    log_warn "Auto-cleanup tracking requires issue number"
  else
    log_info "Registering PR #$PR_NUMBER for auto-cleanup after merge..."

    add_cleanup_intent "$ISSUE" "$PR_NUMBER" "$BRANCH" "$WORKTREE_PATH" "$MODE"

    echo ""
    echo -e "${GREEN}✓ Auto-cleanup enabled${NC}"
    echo ""
    echo "After PR #$PR_NUMBER is merged:"
    if [ "$MODE" = "worktree" ]; then
      echo "  - Worktree will be removed: $WORKTREE_PATH"
      echo "  - Branch will be deleted: $BRANCH"
    else
      echo "  - Container will be stopped and removed"
    fi
    echo ""
    echo "To trigger cleanup manually after merge:"
    echo "  ./scripts/auto-cleanup-merged.sh --issue $ISSUE"
    echo ""
    echo "Or cleanup all merged PRs:"
    echo "  ./scripts/auto-cleanup-merged.sh --all"
  fi
fi

exit 0
