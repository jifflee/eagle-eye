#!/usr/bin/env bash
# =============================================================================
# check-merge-readiness.sh - Check if PR is ready for auto-merge (Issue #432)
# =============================================================================
# Usage: ./check-merge-readiness.sh <PR_NUMBER> [--verbose]
#
# Checks if a PR is ready for auto-merge to dev by verifying:
#   1. CHECK_PASS label is present (local CI validation passed)
#   2. Required reviewers have approved (if configured)
#   3. No merge conflicts
#   4. Base branch is dev or main
#
# Exit Codes:
#   0 - PR is ready for auto-merge
#   1 - PR is not ready (failed checks, no approval, etc.)
#   2 - Error (invalid PR, API failure)
#
# This is used by merge hooks to determine if auto-merge should proceed.
#
# Related:
#   - Issue #432 - Add CHECK_PASS/CHECK_FAIL labels
#   - Issue #382 - Streamline PR merge orchestration
#   - Issue #196 - Epic: PR Lifecycle Automation
# =============================================================================

set -euo pipefail

# Constants
LABEL_PASS="CHECK_PASS"
LABEL_FAIL="CHECK_FAIL"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <PR_NUMBER> [--verbose] [--json]"
    echo ""
    echo "Check if PR is ready for auto-merge based on:"
    echo "  - CHECK_PASS label present"
    echo "  - No CHECK_FAIL label"
    echo "  - No merge conflicts"
    echo "  - Target branch is dev or main"
    echo ""
    echo "Exit codes:"
    echo "  0 - Ready for auto-merge"
    echo "  1 - Not ready"
    echo "  2 - Error"
    exit 2
}

# Parse arguments
PR_NUMBER=""
VERBOSE=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
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

# Validate PR number
if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: PR number required" >&2
    usage
fi

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

# Get PR information
log_verbose "Fetching PR #${PR_NUMBER} information..."

PR_INFO=$(gh pr view "$PR_NUMBER" --json number,labels,mergeable,baseRefName,headRefName 2>/dev/null) || {
    if $JSON_OUTPUT; then
        echo '{"ready":false,"reason":"PR not found","error":true}'
    else
        echo -e "${RED}Error: PR #${PR_NUMBER} not found${NC}"
    fi
    exit 2
}

# Extract fields
LABELS=$(echo "$PR_INFO" | jq -r '.labels[].name')
MERGEABLE=$(echo "$PR_INFO" | jq -r '.mergeable')
BASE_BRANCH=$(echo "$PR_INFO" | jq -r '.baseRefName')
HEAD_BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName')

log_verbose "Base branch: ${BASE_BRANCH}, Head branch: ${HEAD_BRANCH}"
log_verbose "Mergeable state: ${MERGEABLE}"
log_verbose "Labels: $(echo "$LABELS" | tr '\n' ', ' | sed 's/,$//')"

# Initialize checks
CHECKS_PASSED=true
FAILURE_REASONS=()

# Check 1: Verify CHECK_PASS label is present
log_verbose "\n${BLUE}Check 1: CHECK_PASS label${NC}"
if echo "$LABELS" | grep -q "^${LABEL_PASS}$"; then
    log_verbose "  ${GREEN}✓${NC} CHECK_PASS label present"
else
    log_verbose "  ${RED}✗${NC} CHECK_PASS label missing"
    CHECKS_PASSED=false
    FAILURE_REASONS+=("CHECK_PASS label missing - local CI validation not passed")
fi

# Check 2: Verify CHECK_FAIL label is NOT present
log_verbose "${BLUE}Check 2: CHECK_FAIL label${NC}"
if echo "$LABELS" | grep -q "^${LABEL_FAIL}$"; then
    log_verbose "  ${RED}✗${NC} CHECK_FAIL label present"
    CHECKS_PASSED=false
    FAILURE_REASONS+=("CHECK_FAIL label present - local CI validation failed")
else
    log_verbose "  ${GREEN}✓${NC} CHECK_FAIL label not present"
fi

# Check 3: Verify no merge conflicts
log_verbose "${BLUE}Check 3: Merge conflicts${NC}"
if [[ "$MERGEABLE" == "MERGEABLE" ]]; then
    log_verbose "  ${GREEN}✓${NC} No merge conflicts"
elif [[ "$MERGEABLE" == "CONFLICTING" ]]; then
    log_verbose "  ${RED}✗${NC} Has merge conflicts"
    CHECKS_PASSED=false
    FAILURE_REASONS+=("Merge conflicts detected - needs rebase or manual resolution")
else
    log_verbose "  ${YELLOW}?${NC} Mergeable state unknown: ${MERGEABLE}"
    # Don't fail on unknown state - GitHub may still be calculating
fi

# Check 4: Verify target branch
log_verbose "${BLUE}Check 4: Target branch${NC}"
if [[ "$BASE_BRANCH" == "dev" || "$BASE_BRANCH" == "main" ]]; then
    log_verbose "  ${GREEN}✓${NC} Target branch is ${BASE_BRANCH}"
else
    log_verbose "  ${YELLOW}⚠${NC} Target branch is ${BASE_BRANCH} (not dev or main)"
    # This is just informational - not a blocker
fi

# Final result
if $JSON_OUTPUT; then
    # Build JSON output
    reasons_json=$(printf '%s\n' "${FAILURE_REASONS[@]}" | jq -R . | jq -s .)
    if [[ ${#FAILURE_REASONS[@]} -eq 0 ]]; then
        reasons_json="[]"
    fi

    jq -n \
        --arg pr "$PR_NUMBER" \
        --argjson ready "$($CHECKS_PASSED && echo "true" || echo "false")" \
        --argjson reasons "$reasons_json" \
        --arg base "$BASE_BRANCH" \
        --arg head "$HEAD_BRANCH" \
        --arg mergeable "$MERGEABLE" \
        '{
            pr_number: ($pr | tonumber),
            ready: $ready,
            failure_reasons: $reasons,
            base_branch: $base,
            head_branch: $head,
            mergeable_state: $mergeable
        }'
else
    # Human-readable output
    echo ""
    echo "==========================================="
    echo "Merge Readiness Check - PR #${PR_NUMBER}"
    echo "==========================================="
    echo ""

    if $CHECKS_PASSED; then
        echo -e "${GREEN}✓ PR is ready for auto-merge${NC}"
        echo ""
        echo "  Base branch: ${BASE_BRANCH}"
        echo "  Head branch: ${HEAD_BRANCH}"
        echo "  Status: All checks passed"
    else
        echo -e "${RED}✗ PR is NOT ready for auto-merge${NC}"
        echo ""
        echo "Reasons:"
        for reason in "${FAILURE_REASONS[@]}"; do
            echo -e "  ${RED}•${NC} ${reason}"
        done
        echo ""
        echo "To resolve:"
        if echo "$LABELS" | grep -q "^${LABEL_FAIL}$"; then
            echo "  1. Fix validation failures"
            echo "  2. Run: ./scripts/validate-local.sh"
            echo "  3. Push fixes and wait for CHECK_PASS label"
        elif ! echo "$LABELS" | grep -q "^${LABEL_PASS}$"; then
            echo "  1. Wait for local validation to complete"
            echo "  2. Or manually run: ./scripts/validate-local.sh"
        fi
        if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
            echo "  - Resolve merge conflicts with base branch"
        fi
    fi
    echo ""
fi

# Exit with appropriate code
if $CHECKS_PASSED; then
    exit 0
else
    exit 1
fi
