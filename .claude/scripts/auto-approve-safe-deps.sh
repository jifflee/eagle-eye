#!/usr/bin/env bash
# =============================================================================
# auto-approve-safe-deps.sh - Auto-approve SAFE dependency PRs
# =============================================================================
# Usage: ./auto-approve-safe-deps.sh [PR_NUMBER] [--all] [--dry-run]
#
# Implements auto-approve pattern from repo-automation-bots for SAFE dependency PRs:
#   - Auto-approves PRs with SAFE verdict from pr-dep-review
#   - Adds 'automerge' label for label-driven auto-merge
#   - Posts approval comment with analysis summary
#
# SAFE criteria (from dep-review-data.sh):
#   - Patch or minor version bump
#   - No imports found in codebase (unused dependency)
#   - OR: Minor bump with no breaking changes in changelog
#
# Exit Codes:
#   0 - PR(s) approved successfully or no action needed
#   1 - PR(s) not safe to approve
#   2 - Error (invalid PR, API failure)
#
# Related:
#   - Issue #1029 - repo-automation-bots pattern evaluation
#   - .claude/commands/pr-dep-review.md
#   - scripts/pr/dep-review-data.sh
# =============================================================================

set -euo pipefail

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
    echo "Auto-approve SAFE dependency PRs and add 'automerge' label."
    echo ""
    echo "Options:"
    echo "  PR_NUMBER    Specific PR to check (default: all dependency PRs)"
    echo "  --all        Explicitly check all dependency PRs"
    echo "  --dry-run    Show what would be approved without approving"
    echo "  --json       Output JSON format"
    echo "  --verbose    Verbose output"
    echo ""
    echo "SAFE criteria:"
    echo "  - Patch or minor version bump"
    echo "  - No imports found (unused dependency)"
    echo "  - OR: Minor bump with no breaking changes"
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

# Get dependency PRs
get_dependency_prs() {
    # Look for PRs from dependabot or with dependency labels
    gh pr list \
        --state open \
        --json number,author,labels,title \
        --jq '.[] | select(
            .author.login == "dependabot[bot]" or
            (.labels[] | .name == "dependencies")
        ) | .number' || true
}

# Check if PR has SAFE verdict
check_pr_verdict() {
    local pr="$1"

    log_verbose "\n${BLUE}Checking PR #${pr} verdict...${NC}"

    # Run dep-review-data.sh to get verdict
    if [[ ! -f "$SCRIPT_DIR/dep-review-data.sh" ]]; then
        log "${RED}Error: dep-review-data.sh not found${NC}"
        return 2
    fi

    local analysis
    analysis=$("$SCRIPT_DIR/dep-review-data.sh" --pr "$pr" 2>/dev/null) || {
        log_verbose "  ${YELLOW}⚠${NC} Not a dependency PR or analysis failed"
        echo "not_dependency"
        return 1
    }

    local verdict=$(echo "$analysis" | jq -r '.prs[0].verdict // "UNKNOWN"')
    local package=$(echo "$analysis" | jq -r '.prs[0].package // "unknown"')
    local from_version=$(echo "$analysis" | jq -r '.prs[0].from_version // "?"')
    local to_version=$(echo "$analysis" | jq -r '.prs[0].to_version // "?"')
    local bump_type=$(echo "$analysis" | jq -r '.prs[0].bump_type // "unknown"')

    log_verbose "  Package: ${package}"
    log_verbose "  Version: ${from_version} → ${to_version} (${bump_type})"
    log_verbose "  Verdict: ${verdict}"

    if [[ "$verdict" == "SAFE" ]]; then
        log_verbose "  ${GREEN}✓${NC} SAFE verdict - eligible for auto-approve"
        echo "$analysis"
        return 0
    else
        log_verbose "  ${YELLOW}⚠${NC} Verdict is ${verdict} - not safe for auto-approve"
        echo "$verdict"
        return 1
    fi
}

# Approve a PR
approve_pr() {
    local pr="$1"
    local analysis="$2"

    local package=$(echo "$analysis" | jq -r '.prs[0].package')
    local from_version=$(echo "$analysis" | jq -r '.prs[0].from_version')
    local to_version=$(echo "$analysis" | jq -r '.prs[0].to_version')
    local bump_type=$(echo "$analysis" | jq -r '.prs[0].bump_type')
    local import_count=$(echo "$analysis" | jq -r '.prs[0].import_count // 0')

    if $DRY_RUN; then
        log "${CYAN}[DRY RUN]${NC} Would approve PR #${pr}"
        log "  Package: ${package}"
        log "  Version: ${from_version} → ${to_version} (${bump_type})"
        log "  Imports: ${import_count}"
        return 0
    fi

    log "${GREEN}Approving PR #${pr}${NC}"

    # Build approval comment
    local comment="🤖 Auto-approved via dependency safety analysis

**Package:** \`${package}\`
**Version:** ${from_version} → ${to_version} (${bump_type} bump)
**Imports:** ${import_count} file(s) use this package
**Verdict:** ✅ SAFE

**Safety criteria met:**
- ✅ Patch or minor version bump
- ✅ No breaking changes detected
- ✅ Low risk for deployment

**Next steps:**
- This PR has been approved and labeled with \`automerge\`
- It will be auto-merged when CI checks pass
- See: docs/REPO_AUTOMATION_BOTS_EVALUATION.md

Analysis generated by: \`/pr-dep-review --pr ${pr}\`"

    # Approve the PR
    if gh pr review "$pr" --approve --body "$comment"; then
        log "${GREEN}✓${NC} Approved PR #${pr}"

        # Add automerge label
        if gh pr edit "$pr" --add-label "automerge"; then
            log "${GREEN}✓${NC} Added 'automerge' label"
        else
            log "${YELLOW}⚠${NC} Failed to add 'automerge' label (may already exist)"
        fi

        return 0
    else
        log "${RED}✗${NC} Failed to approve PR #${pr}"
        return 1
    fi
}

# Process a single PR
process_pr() {
    local pr="$1"
    local verdict_result

    verdict_result=$(check_pr_verdict "$pr")
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        # SAFE verdict
        if approve_pr "$pr" "$verdict_result"; then
            echo "approved"
            return 0
        else
            echo "approval_failed"
            return 1
        fi
    else
        # Not SAFE or not a dependency PR
        echo "$verdict_result"
        return $exit_code
    fi
}

# Main logic
main() {
    local prs=()

    if [[ -n "$PR_NUMBER" ]]; then
        # Single PR mode
        prs=("$PR_NUMBER")
        log "Checking PR #${PR_NUMBER} for auto-approve..."
    else
        # All dependency PRs
        log "Searching for dependency PRs..."

        mapfile -t prs < <(get_dependency_prs)

        if [[ ${#prs[@]} -eq 0 ]]; then
            if $JSON_OUTPUT; then
                echo '{"status":"no_prs","prs":[],"summary":"No dependency PRs found"}'
            else
                log "\n${YELLOW}No dependency PRs found${NC}"
            fi
            exit 0
        fi

        log "Found ${#prs[@]} dependency PR(s)"
    fi

    # Process each PR
    local results=()
    local approved_count=0
    local skipped_count=0
    local failed_count=0

    for pr in "${prs[@]}"; do
        local result
        result=$(process_pr "$pr")
        local exit_code=$?

        results+=("{\"pr\":$pr,\"status\":\"$result\"}")

        case "$result" in
            approved)
                ((approved_count++)) || true
                ;;
            approval_failed)
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
            --argjson approved "$approved_count" \
            --argjson skipped "$skipped_count" \
            --argjson failed "$failed_count" \
            --argjson prs "$results_json" \
            '{
                approved: $approved,
                skipped: $skipped,
                failed: $failed,
                prs: $prs
            }'
    else
        log "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "${BLUE}Auto-Approve Summary${NC}"
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "  ${GREEN}Approved:${NC} $approved_count"
        log "  ${YELLOW}Skipped:${NC}  $skipped_count"
        log "  ${RED}Failed:${NC}   $failed_count"
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

        if [[ $approved_count -gt 0 ]]; then
            log "${GREEN}✓${NC} Auto-approved $approved_count SAFE dependency PR(s)"
            log "  PRs labeled with 'automerge' will merge automatically when CI passes"
        fi
    fi

    # Exit based on results
    if [[ $failed_count -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main
