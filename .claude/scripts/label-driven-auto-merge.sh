#!/usr/bin/env bash
# =============================================================================
# label-driven-auto-merge.sh - Auto-merge PRs with 'automerge' label
# =============================================================================
# Usage: ./label-driven-auto-merge.sh [PR_NUMBER] [--all] [--dry-run]
#
# Implements label-driven auto-merge pattern from repo-automation-bots:
#   - Merges PRs with 'automerge' label when ready
#   - Respects 'do-not-merge' label as safety override
#   - Requires CHECK_PASS label and all CI checks passed
#
# Exit Codes:
#   0 - PR(s) merged successfully or no action needed
#   1 - PR(s) not ready for merge
#   2 - Error (invalid PR, API failure)
#
# Related:
#   - Issue #1029 - repo-automation-bots pattern evaluation
#   - docs/REPO_AUTOMATION_BOTS_EVALUATION.md
#   - docs/CI_CHECK_LABELS.md
# =============================================================================

set -euo pipefail

# Constants
LABEL_AUTOMERGE="automerge"
LABEL_DO_NOT_MERGE="do-not-merge"
LABEL_CHECK_PASS="CHECK_PASS"
LABEL_CHECK_FAIL="CHECK_FAIL"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 [PR_NUMBER] [--all] [--dry-run] [--json]"
    echo ""
    echo "Auto-merge PRs with 'automerge' label when ready."
    echo ""
    echo "Options:"
    echo "  PR_NUMBER    Specific PR to check (default: all PRs with automerge label)"
    echo "  --all        Explicitly check all PRs with automerge label"
    echo "  --dry-run    Show what would be merged without merging"
    echo "  --json       Output JSON format"
    echo "  --verbose    Verbose output"
    echo ""
    echo "Merge criteria:"
    echo "  - Has 'automerge' label"
    echo "  - No 'do-not-merge' label"
    echo "  - Has 'CHECK_PASS' label"
    echo "  - No 'CHECK_FAIL' label"
    echo "  - No merge conflicts"
    echo "  - All CI checks passed"
    echo ""
    exit 2
}

# Parse arguments
PR_NUMBER=""
CHECK_ALL=false
DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            CHECK_ALL=true
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
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$PR_NUMBER" && "$1" =~ ^[0-9]+$ ]]; then
                PR_NUMBER="$1"
            else
                echo "Error: Unknown argument: $1" >&2
                usage
            fi
            shift
            ;;
    esac
done

log() {
    if ! $JSON_OUTPUT; then
        echo -e "$1" >&2
    fi
}

log_verbose() {
    if $VERBOSE && ! $JSON_OUTPUT; then
        echo -e "$1" >&2
    fi
}

# Get PRs with automerge label
get_automerge_prs() {
    gh pr list \
        --state open \
        --label "$LABEL_AUTOMERGE" \
        --json number,title,baseRefName,labels \
        --jq '.[] | .number' || true
}

# Check if PR is ready for auto-merge
check_pr_ready() {
    local pr="$1"

    log_verbose "\n${BLUE}Checking PR #${pr}...${NC}"

    # Get PR info
    local pr_info
    pr_info=$(gh pr view "$pr" \
        --json number,title,labels,mergeable,baseRefName,headRefName,state 2>/dev/null) || {
        log "${RED}Error: Failed to fetch PR #${pr}${NC}"
        return 2
    }

    local title=$(echo "$pr_info" | jq -r '.title')
    local state=$(echo "$pr_info" | jq -r '.state')
    local labels=$(echo "$pr_info" | jq -r '.labels[].name')
    local mergeable=$(echo "$pr_info" | jq -r '.mergeable')
    local base_branch=$(echo "$pr_info" | jq -r '.baseRefName')

    log_verbose "  Title: ${title}"
    log_verbose "  Base: ${base_branch}"
    log_verbose "  State: ${state}"

    # Check if PR is open
    if [[ "$state" != "OPEN" ]]; then
        log_verbose "  ${YELLOW}⚠${NC} PR is not open (state: ${state})"
        echo "not_open"
        return 1
    fi

    # Check for automerge label
    if ! echo "$labels" | grep -q "^${LABEL_AUTOMERGE}$"; then
        log_verbose "  ${YELLOW}⚠${NC} Missing 'automerge' label"
        echo "no_automerge_label"
        return 1
    fi

    # Check for do-not-merge label (safety override)
    if echo "$labels" | grep -q "^${LABEL_DO_NOT_MERGE}$"; then
        log_verbose "  ${RED}✗${NC} Has 'do-not-merge' label (blocked)"
        echo "do_not_merge"
        return 1
    fi

    # Check for CHECK_PASS label
    if ! echo "$labels" | grep -q "^${LABEL_CHECK_PASS}$"; then
        log_verbose "  ${RED}✗${NC} Missing 'CHECK_PASS' label"
        echo "no_check_pass"
        return 1
    fi

    # Check for CHECK_FAIL label
    if echo "$labels" | grep -q "^${LABEL_CHECK_FAIL}$"; then
        log_verbose "  ${RED}✗${NC} Has 'CHECK_FAIL' label"
        echo "check_fail"
        return 1
    fi

    # Check for merge conflicts
    if [[ "$mergeable" != "MERGEABLE" ]]; then
        log_verbose "  ${RED}✗${NC} Not mergeable (state: ${mergeable})"
        echo "not_mergeable"
        return 1
    fi

    # Use check-merge-readiness.sh for comprehensive validation
    if [[ -f "$SCRIPT_DIR/pr/check-merge-readiness.sh" ]]; then
        if ! "$SCRIPT_DIR/pr/check-merge-readiness.sh" "$pr" --json >/dev/null 2>&1; then
            log_verbose "  ${RED}✗${NC} Failed merge readiness check"
            echo "not_ready"
            return 1
        fi
    fi

    log_verbose "  ${GREEN}✓${NC} Ready for auto-merge"
    echo "ready"
    return 0
}

# Merge a PR
merge_pr() {
    local pr="$1"
    local pr_info

    pr_info=$(gh pr view "$pr" --json number,title,headRefName)
    local title=$(echo "$pr_info" | jq -r '.title')
    local branch=$(echo "$pr_info" | jq -r '.headRefName')

    if $DRY_RUN; then
        log "${CYAN}[DRY RUN]${NC} Would merge PR #${pr}: ${title}"
        log "  Branch: ${branch}"
        log "  Strategy: squash"
        log "  Delete branch: yes"
        return 0
    fi

    log "${GREEN}Merging PR #${pr}: ${title}${NC}"

    # Merge with squash and delete branch
    if gh pr merge "$pr" --squash --delete-branch --auto; then
        log "${GREEN}✓${NC} Successfully merged PR #${pr}"

        # Post success comment
        gh pr comment "$pr" --body "🤖 Auto-merged via label-driven auto-merge (automerge label detected)

**Merge criteria met:**
- ✅ \`automerge\` label present
- ✅ No \`do-not-merge\` label
- ✅ \`CHECK_PASS\` label present
- ✅ All CI checks passed
- ✅ No merge conflicts

See: docs/REPO_AUTOMATION_BOTS_EVALUATION.md" 2>/dev/null || true

        return 0
    else
        log "${RED}✗${NC} Failed to merge PR #${pr}"
        return 1
    fi
}

# Process a single PR
process_pr() {
    local pr="$1"
    local ready_status

    ready_status=$(check_pr_ready "$pr")
    local exit_code=$?

    if [[ "$ready_status" == "ready" ]]; then
        if merge_pr "$pr"; then
            echo "merged"
            return 0
        else
            echo "merge_failed"
            return 1
        fi
    else
        echo "$ready_status"
        return $exit_code
    fi
}

# Main logic
main() {
    local prs=()

    if [[ -n "$PR_NUMBER" ]]; then
        # Single PR mode
        prs=("$PR_NUMBER")
        log "Checking PR #${PR_NUMBER} for auto-merge..."
    else
        # All PRs with automerge label
        log "Searching for PRs with '${LABEL_AUTOMERGE}' label..."

        mapfile -t prs < <(get_automerge_prs)

        if [[ ${#prs[@]} -eq 0 ]]; then
            if $JSON_OUTPUT; then
                echo '{"status":"no_prs","prs":[],"summary":"No PRs with automerge label found"}'
            else
                log "\n${YELLOW}No PRs found with '${LABEL_AUTOMERGE}' label${NC}"
            fi
            exit 0
        fi

        log "Found ${#prs[@]} PR(s) with '${LABEL_AUTOMERGE}' label"
    fi

    # Process each PR
    local results=()
    local merged_count=0
    local skipped_count=0
    local failed_count=0

    for pr in "${prs[@]}"; do
        local result
        result=$(process_pr "$pr")
        local exit_code=$?

        results+=("{\"pr\":$pr,\"status\":\"$result\"}")

        case "$result" in
            merged)
                ((merged_count++)) || true
                ;;
            merge_failed)
                ((failed_count++)) || true
                ;;
            *)
                ((skipped_count++)) || true
                ;;
        esac
    done

    # Output results
    if $JSON_OUTPUT; then
        local results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
        jq -n \
            --argjson merged "$merged_count" \
            --argjson skipped "$skipped_count" \
            --argjson failed "$failed_count" \
            --argjson prs "$results_json" \
            '{
                merged: $merged,
                skipped: $skipped,
                failed: $failed,
                prs: $prs
            }'
    else
        log "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "${BLUE}Auto-Merge Summary${NC}"
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "  ${GREEN}Merged:${NC}  $merged_count"
        log "  ${YELLOW}Skipped:${NC} $skipped_count"
        log "  ${RED}Failed:${NC}  $failed_count"
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    fi

    # Exit based on results
    if [[ $failed_count -gt 0 ]]; then
        exit 1
    elif [[ $merged_count -gt 0 ]]; then
        exit 0
    else
        exit 0  # No errors, just nothing to merge
    fi
}

main
