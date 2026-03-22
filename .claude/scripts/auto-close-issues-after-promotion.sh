#!/bin/bash
set -euo pipefail
# auto-close-issues-after-promotion.sh
#
# DEPRECATED (Issue #1335): This script is no longer needed.
#
# Issues are now closed immediately when their PR merges to 'dev' by:
#   - /pr:merge-batch skill (closes linked issues after each successful merge)
#   - scripts/worktree/worktree-complete.sh (closes issue after PR merge)
#
# This script is retained for historical reference and manual fallback only.
# It will be removed in a future cleanup pass.
#
# Original purpose: Automatically close issues linked to PRs after promotion to main
#
# GitHub only auto-closes issues when PRs are merged to the DEFAULT branch.
# Since our PRs merge to 'dev' first, issues remain open even with "Fixes #N".
# This script closed issues after their PRs are promoted to main (now superseded).
#
# Usage:
#   ./scripts/auto-close-issues-after-promotion.sh [--pr PR_NUMBER]
#   ./scripts/auto-close-issues-after-promotion.sh --recent N
#   ./scripts/auto-close-issues-after-promotion.sh --all
#
# Part of: Issue #622 - Container PRs missing auto-close behavior
# Superseded by: Issue #1335 - Close issues on PR merge to dev

echo "[DEPRECATED] auto-close-issues-after-promotion.sh is superseded by Issue #1335." >&2
echo "[DEPRECATED] Issues are now closed immediately when PRs merge to dev." >&2
echo "[DEPRECATED] This script will be removed in a future cleanup pass." >&2
echo "" >&2

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities if available
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    source "$SCRIPT_DIR/lib/common.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*"; }
    log_success() { echo "[OK] $*"; }
fi

usage() {
    cat << 'EOF'
auto-close-issues-after-promotion.sh - Close issues after PRs promoted to main

USAGE:
    ./scripts/auto-close-issues-after-promotion.sh [OPTIONS]

OPTIONS:
    --pr N          Close issue linked to specific PR number
    --recent N      Check N most recent merged PRs (default: 10)
    --all           Check all merged PRs (may be slow)
    --dry-run       Show what would be closed without closing
    --help          Show this help

DESCRIPTION:
    GitHub only auto-closes issues when PRs merge to the default branch (main).
    Since PRs merge to 'dev' first, issues with "Fixes #N" don't auto-close.

    This script:
    1. Finds PRs merged to main (promoted from dev)
    2. Extracts "Fixes #N" from PR bodies
    3. Closes those issues if still open

EXAMPLES:
    # Close issue from specific PR
    ./scripts/auto-close-issues-after-promotion.sh --pr 615

    # Check 20 most recent PRs
    ./scripts/auto-close-issues-after-promotion.sh --recent 20

    # Preview without closing
    ./scripts/auto-close-issues-after-promotion.sh --recent 10 --dry-run

EOF
}

# Parse arguments
PR_NUMBER=""
RECENT=10
CHECK_ALL=false
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --pr)
            PR_NUMBER="$2"
            shift 2
            ;;
        --recent)
            RECENT="$2"
            shift 2
            ;;
        --all)
            CHECK_ALL=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Extract issue numbers from PR body (supports multiple formats)
extract_issues_from_pr() {
    local pr_number="$1"
    local pr_body

    pr_body=$(gh pr view "$pr_number" --json body -q '.body' 2>/dev/null || echo "")

    if [ -z "$pr_body" ]; then
        return
    fi

    # Extract all "Fixes #N", "Closes #N", "Resolves #N" patterns
    echo "$pr_body" | grep -oiE '(fixes|closes|resolves) #[0-9]+' | grep -oE '[0-9]+' | sort -u
}

# Close a single issue
close_issue() {
    local issue_number="$1"
    local pr_number="$2"
    local issue_state

    issue_state=$(gh issue view "$issue_number" --json state -q '.state' 2>/dev/null || echo "")

    if [ "$issue_state" = "CLOSED" ]; then
        log_info "Issue #$issue_number already closed (skipping)"
        return 0
    fi

    if [ "$issue_state" != "OPEN" ]; then
        log_warn "Issue #$issue_number not found or invalid state: $issue_state"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would close issue #$issue_number (linked to PR #$pr_number)"
        return 0
    fi

    log_info "Closing issue #$issue_number (linked to PR #$pr_number)"

    if gh issue close "$issue_number" --comment "Automatically closed after PR #$pr_number was promoted to main" 2>&1; then
        log_success "Closed issue #$issue_number"
        return 0
    else
        log_error "Failed to close issue #$issue_number"
        return 1
    fi
}

# Process a single PR
process_pr() {
    local pr_number="$1"
    local issues

    log_info "Processing PR #$pr_number..."

    issues=$(extract_issues_from_pr "$pr_number")

    if [ -z "$issues" ]; then
        log_info "No linked issues found in PR #$pr_number"
        return 0
    fi

    while IFS= read -r issue_number; do
        close_issue "$issue_number" "$pr_number"
    done <<< "$issues"
}

# Main execution
main() {
    if [ -n "$PR_NUMBER" ]; then
        # Process single PR
        process_pr "$PR_NUMBER"
    else
        # Process multiple PRs
        local limit=""
        if [ "$CHECK_ALL" = false ]; then
            limit="--limit $RECENT"
        fi

        log_info "Fetching merged PRs..."

        # Get PRs merged to main
        local prs
        prs=$(gh pr list --state merged --base main $limit --json number -q '.[].number' 2>/dev/null || echo "")

        if [ -z "$prs" ]; then
            log_warn "No merged PRs found"
            return 0
        fi

        local pr_count
        pr_count=$(echo "$prs" | wc -l | tr -d ' ')
        log_info "Found $pr_count merged PRs to check"

        while IFS= read -r pr; do
            process_pr "$pr"
        done <<< "$prs"
    fi

    log_success "Done"
}

main
